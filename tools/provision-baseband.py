#!/usr/bin/env python3
"""Import private, manifested support into an offline image and enable guarded boot."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parents[1]
SUPPORT = Path('var/lib/mtk-ccci/qqcandy-532')


def load_prepare():
    spec = importlib.util.spec_from_file_location('prepare_owner', HERE / 'baseband/prepare-owner.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prepare = load_prepare()


def support_files(source):
    reviewed = json.loads((HERE / 'baseband/qqcandy-532.json').read_text())
    entries = json.loads((source / 'support-manifest.json').read_text())['files']
    files = {}
    modules = {}
    for item in entries:
        name, digest = item['path'], item['sha256']
        path = prepare.safe_path(source, name)
        if name.startswith('modules/') and name[8:] in reviewed['modules']:
            destination = name
            modules[name[8:]] = digest
        elif name.startswith('private/vendor-md/'):
            destination = 'vendor/etc/md/' + name[len('private/vendor-md/'):]
        elif name.startswith('private/overlay/'):
            destination = name
        else:
            raise ValueError('unsupported support manifest entry')
        if destination in files or not path.is_file():
            raise ValueError('duplicate or missing support file')
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('private support seed hash mismatch')
        files[destination] = (path, digest)
    if modules != reviewed['modules']:
        raise ValueError('support modules not the reviewed #532 build')
    if not any(name.startswith('vendor/etc/md/') for name in files):
        raise ValueError('missing private vendor data')
    if not any(name.startswith('private/overlay/') for name in files):
        raise ValueError('missing private COW seed')
    return reviewed, files


def profile_for(files):
    return {'schema': 1, 'integration': 'qqcandy-532', 'support_root': '/' + str(SUPPORT),
            'immutable_files': {name: digest for name, (_, digest) in files.items()
                                if not name.startswith('private/overlay/')}}


def write_file(root, name, content, mode=0o600):
    path = prepare.safe_path(root, name)
    if path.exists():
        raise ValueError('refusing to replace existing deployment configuration: ' + name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(mode)


def owner_environment(reviewed):
    return {
        'MTK_CCCI_BOARD': 'qqcandy', 'MTK_CCCI_EXPECTED_KERNEL': reviewed['kernel'],
        'MTK_CCCI_EXPECTED_NOTES_SHA256': reviewed['notes_sha256'],
        'MTK_CCCI_VENDOR_ROOT': '/mnt/vendor',
        'MTK_CCCI_VENDOR_ETC_ROOT': '/' + str(SUPPORT / 'vendor'),
        'MTK_CCCI_PRIVATE_ROOT': '/' + str(SUPPORT / 'private-data'),
        'MDINIT_OVERLAY_ROOT': '/' + str(SUPPORT / 'private/overlay'),
        'CCCI_EVIDENCE_DIR': '/' + str(SUPPORT / 'evidence'), 'MTK_CCCI_ENABLE_MDLOG': '0',
    }


def provision(root, source, distro):
    if root == Path('/'):
        raise ValueError('offline rootfs required; not a running system')
    reviewed, files = support_files(source)
    destination = prepare.safe_path(root, str(SUPPORT))
    if destination.exists():
        raise ValueError('preserving existing private support/COW; no overwrite permitted')
    required = ['usr/libexec/mtk-ccci/start-owner', 'usr/libexec/mtk-ccci/ModemManager',
                'usr/libexec/mtk-ccci/prepare-owner.py', 'usr/libexec/mtk-ccci/run-limited.py']
    units = ('etc/init.d/' if distro == 'nura' else 'usr/lib/systemd/system/')
    suffix = '' if distro == 'nura' else '.service'
    required += [units + name + suffix for name in ('mtk-ccci-prepare', 'mtk-ccci-owner', 'mtk-modemmanager')]
    if not all(prepare.safe_path(root, name).is_file() for name in required):
        raise ValueError('install the tested baseband bundle and boot integration first')
    config_names = ['etc/default/mtk-ccci', 'etc/mtk-ccci/boot-profile.json',
                    'usr/local/share/dbus-1/system-services/org.freedesktop.ModemManager1.service',
                    'usr/share/mt6895-build/baseband-boot.json']
    if any(prepare.safe_path(root, name).exists() for name in config_names):
        raise ValueError('existing boot configuration; preserving it unchanged')
    destination.mkdir(parents=True, mode=0o700)
    for name, (source_file, _) in files.items():
        output = prepare.safe_path(destination, name)
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_file, output)
        output.chmod(0o600 if name.startswith('private/overlay/') else 0o400)
    for name in ('private-data', 'evidence'):
        (destination / name).mkdir(mode=0o700)
    for directory in destination.rglob('*'):
        if directory.is_dir():
            directory.chmod(0o700)
    profile = profile_for(files)
    prepare.validate_support(profile, destination, reviewed)
    env = owner_environment(reviewed)
    write_file(root, config_names[0], ''.join(name + '=' + value + '\n' for name, value in env.items()))
    write_file(root, config_names[1], json.dumps(profile, indent=2) + '\n')
    write_file(root, config_names[2], '[D-BUS Service]\nName=org.freedesktop.ModemManager1\nExec=/bin/false\nUser=root\n', 0o644)
    write_file(root, config_names[3], json.dumps({'schema': 1, 'integration': 'qqcandy-532',
               'autostart': True, 'hardware_validated': False, 'private_support': True}, indent=2) + '\n')
    if distro == 'nura':
        for entry in (root / 'etc/runlevels').glob('*/modemmanager'):
            if not entry.is_symlink():
                raise ValueError('unexpected distribution MM runlevel entry')
            entry.unlink()
        runlevel = prepare.safe_path(root, 'etc/runlevels/default')
        runlevel.mkdir(parents=True, exist_ok=True)
        for service in ('mtk-ccci-owner', 'mtk-modemmanager'):
            (runlevel / service).symlink_to('/etc/init.d/' + service)
    else:
        # Mask even D-Bus-triggered distribution startup; the bundle owns its name.
        mask = prepare.safe_path(root, 'etc/systemd/system/ModemManager.service')
        if mask.exists() or mask.is_symlink():
            raise ValueError('preserving an existing administrator MM unit')
        mask.parent.mkdir(parents=True, exist_ok=True)
        mask.symlink_to('/dev/null')
        wants = prepare.safe_path(root, 'etc/systemd/system/multi-user.target.wants')
        wants.mkdir(parents=True, exist_ok=True)
        for service in ('mtk-ccci-owner', 'mtk-modemmanager'):
            (wants / (service + '.service')).symlink_to('/usr/lib/systemd/system/' + service + '.service')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--distro', choices=('mobian', 'debian', 'arch', 'nura'))
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    try:
        source = args.source.absolute()
        if source.resolve() != source:
            raise ValueError('support source contains a symlink')
        if args.check_only:
            support_files(source)
        else:
            if os.geteuid() != 0 or args.root is None or args.distro is None:
                raise ValueError('root, --root and --distro required')
            root = args.root.absolute()
            if root.resolve() != root or not root.is_dir():
                raise ValueError('invalid offline rootfs')
            provision(root, source, args.distro)
        print('Private support contracts passed; no hardware started')
        return 0
    except (OSError, KeyError, TypeError, ValueError) as error:
        print('Baseband provisioning refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
