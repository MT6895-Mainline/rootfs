import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


provision = load('provision', HERE / 'tools/provision-baseband.py')
limited = load('limited', HERE / 'baseband/run-limited.py')
prepare = provision.prepare


class BootProfileTests(unittest.TestCase):
    def fixture(self, directory, distro='nura'):
        root, source, project = (directory / name for name in ('root', 'support', 'project'))
        root.mkdir()
        source.mkdir()
        (project / 'baseband').mkdir(parents=True)
        reviewed = json.loads((HERE / 'baseband/qqcandy-532.json').read_text())
        entries = []
        for name in ['modules/' + name for name in reviewed['modules']] + [
                'private/overlay/Z/seed', 'private/vendor-md/cert/seed']:
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            entries.append({'path': name, 'sha256': digest})
            if name.startswith('modules/'):
                reviewed['modules'][name[8:]] = digest
        (source / 'support-manifest.json').write_text(json.dumps({'files': entries}))
        (project / 'baseband/qqcandy-532.json').write_text(json.dumps(reviewed))
        for name in ('start-owner', 'ModemManager', 'prepare-owner.py', 'run-limited.py'):
            path = root / 'usr/libexec/mtk-ccci' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        for name in ('mtk-ccci-prepare', 'mtk-ccci-owner', 'mtk-modemmanager'):
            path = (root / 'etc/init.d' / name if distro == 'nura' else
                    root / 'usr/lib/systemd/system' / (name + '.service'))
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(HERE / 'baseband' / (name + ('.initd' if distro == 'nura' else '.service')), path)
        return root, source, project, reviewed

    def test_offline_boot_profile_all_backends_and_mutable_cow(self):
        for distro in ('nura', 'mobian', 'arch'):
            with self.subTest(distro=distro), tempfile.TemporaryDirectory() as directory:
                root, source, project, reviewed = self.fixture(Path(directory), distro)
                with patch.object(provision, 'HERE', project):
                    provision.provision(root, source, distro)
                    with self.assertRaisesRegex(ValueError, 'preserving existing'):
                        provision.provision(root, source, distro)
                support = root / provision.SUPPORT
                profile = json.loads((root / 'etc/mtk-ccci/boot-profile.json').read_text())
                self.assertEqual(support.stat().st_mode & 0o777, 0o700)
                self.assertTrue(all(not name.startswith('private/overlay/')
                                    for name in profile['immutable_files']))
                (support / 'private/overlay/Z/seed').write_text('legitimate COW update')
                prepare.validate_support(profile, support, reviewed)
                immutable = support / 'vendor/etc/md/cert/seed'
                self.assertEqual(immutable.stat().st_mode & 0o777, 0o400)
                immutable.chmod(0o600)
                immutable.write_text('corrupt immutable support')
                with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                    prepare.validate_support(profile, support, reviewed)
                if distro == 'nura':
                    self.assertEqual(os.readlink(root / 'etc/runlevels/default/mtk-modemmanager'),
                                     '/etc/init.d/mtk-modemmanager')
                else:
                    self.assertEqual(os.readlink(root / 'etc/systemd/system/ModemManager.service'), '/dev/null')

    def test_source_corruption_and_symlinks_refused_before_import(self):
        with tempfile.TemporaryDirectory() as directory:
            root, source, project, _ = self.fixture(Path(directory))
            with patch.object(provision, 'HERE', project):
                file = source / 'private/overlay/Z/seed'
                file.write_text('corruption')
                with self.assertRaisesRegex(ValueError, 'seed hash mismatch'):
                    provision.provision(root, source, 'nura')
                self.assertFalse((root / provision.SUPPORT).exists())
                file.unlink()
                file.symlink_to('/etc/passwd')
                with self.assertRaisesRegex(ValueError, 'symlink'):
                    provision.provision(root, source, 'nura')

    def test_unreviewed_module_and_incomplete_source_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            _, source, project, _ = self.fixture(Path(directory))
            with patch.object(provision, 'HERE', project):
                manifest = source / 'support-manifest.json'
                data = json.loads(manifest.read_text())
                data['files'] = data['files'][1:]
                manifest.write_text(json.dumps(data))
                with self.assertRaisesRegex(ValueError, 'reviewed #532'):
                    provision.support_files(source)

    def test_runtime_support_rejects_mutable_hashes_and_path_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('../secret', '/secret'):
                with self.assertRaises(ValueError):
                    prepare.safe_path(root, name)
            (root / 'link').symlink_to('/tmp')
            with self.assertRaises(ValueError):
                prepare.safe_path(root, 'link/secret')
            with self.assertRaises(ValueError):
                prepare.validate_support({'schema': 1, 'integration': 'qqcandy-532',
                    'support_root': '/other', 'immutable_files': {}}, root, {'modules': {}})

    def test_nv_requires_exact_ro_noload_ext4_and_device(self):
        mount = {'target': '/mnt/vendor/nvdata', 'source': '/dev/expected',
                 'fstype': 'ext4', 'options': 'ro,norecovery'}
        prepare.validate_mount({'filesystems': [mount]}, Path(mount['target']), Path('/dev/expected'))
        for field, value in (('options', 'ro'), ('options', 'rw,noload'),
                             ('fstype', 'f2fs'), ('source', '/dev/other'), ('target', '/mnt/vendor')):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                prepare.validate_mount({'filesystems': [dict(mount, **{field: value})]},
                                       Path('/mnt/vendor/nvdata'), Path('/dev/expected'))

    def test_mm_deadline_is_before_owner_and_rejects_stale_boot_pid(self):
        info = {'boot': 'boot', 'pid': os.getpid(), 'start_ticks': limited.start_ticks(os.getpid()),
                'deadline': 86400}
        self.assertEqual(limited.remaining(info, 'boot', 0), 86370)
        for broken, boot, now in [(info, 'other', 0), (dict(info, start_ticks='other'), 'boot', 0),
                                   (info, 'boot', 86371), (dict(info, deadline=90000), 'boot', 0)]:
            with self.assertRaises(ValueError):
                limited.remaining(broken, boot, now)

    def test_live_root_is_not_an_offline_provisioning_target(self):
        with self.assertRaisesRegex(ValueError, 'offline rootfs'):
            provision.provision(Path('/'), Path('/unused'), 'nura')

    def test_bounded_wrapper_waits_for_child_and_terminates_at_deadline(self):
        timeout = shutil.which('timeout')
        if timeout is None:
            self.skipTest('timeout utility unavailable')
        self.assertEqual(limited.run_child(timeout, 2, 1, ['/bin/true']), 0)
        self.assertIn(limited.run_child(timeout, 1, 1, ['/bin/sleep', '5']), (124, 143))

    def test_vibrator_rule_matches_only_the_verified_input_name(self):
        rule = (HERE / 'overlay/qqcandy/etc/udev/rules.d/72-qqcandy-feedback.rules').read_text()
        self.assertIn('ATTRS{name}=="aw8697-haptics"', rule)
        self.assertIn('ENV{FEEDBACKD_TYPE}="vibra"', rule)
        self.assertIn('TAG+="uaccess"', rule)
        self.assertIn('ACTION!="remove"', rule)


if __name__ == '__main__':
    unittest.main()
