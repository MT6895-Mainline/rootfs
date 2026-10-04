import json
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest

HERE = Path(__file__).parents[1]
NATIVE = HERE / 'ui/phosh/qqcandy-native'
spec = importlib.util.spec_from_file_location('cutout_contracts', HERE / 'tools/validate-rootfs.py')
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)


class CutoutTests(unittest.TestCase):
    def image(self, root):
        def write(name, content):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            return path

        elf = b'\x7fELF\x02\x01' + b'\0' * 12 + b'\xb7\0'
        for name in ('usr/libexec/phosh', 'usr/bin/phrog', 'usr/lib/libphosh-0.45.so.0',
                     'usr/lib/qqcandy-phosh/phosh', 'usr/lib/qqcandy-phosh/libphosh-0.45.so.0'):
            write(name, elf)
        for name in ('shell', 'greeter'):
            write('usr/libexec/qqcandy-phosh/' + name, (NATIVE / name).read_bytes()).chmod(0o755)
        write('usr/share/qqcandy-phosh/panels/oplus,qqcandy.json', (NATIVE / 'panels/oplus,qqcandy.json').read_bytes())
        write('etc/phrog/greetd-config.toml', (NATIVE / 'greetd-config.toml').read_bytes())
        write('usr/share/qqcandy-phosh/original-greetd-config.toml',
              b'[terminal]\nvt=7\n[default_session]\ncommand="/usr/libexec/phrog-greetd-session"\nuser="greetd"\n')
        write('usr/share/applications/mobi.phosh.Shell.desktop', b'[Desktop Entry]\nExec=/usr/libexec/phosh\n')
        write('usr/local/share/applications/mobi.phosh.Shell.desktop', b'[Desktop Entry]\nExec=/usr/libexec/qqcandy-phosh/shell\n')
        marker = {'schema': 1, 'device': 'qqcandy', 'distro': 'nura', 'phosh_version': '0.57.0',
                  'phrog_version': '0.53.0', 'hardware_validated': False,
                  'patch_sha256': hashlib.sha256((HERE / 'ui/phosh/patches/0001-top-bar-cutout-height.patch').read_bytes()).hexdigest()}
        write('usr/share/mt6895-build/phosh-cutout.json', json.dumps(marker).encode())

    def test_installed_image_contracts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.image(root)
            contracts.validate_cutout(root)

    def test_rejects_wrong_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.image(root)
            path = root / 'usr/lib/qqcandy-phosh/phosh'
            path.write_bytes(path.read_bytes()[:18] + b'\x3e\0')
            with self.assertRaisesRegex(ValueError, 'not AArch64'):
                contracts.validate_cutout(root)

    def test_rejects_unactivated_greeter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.image(root)
            (root / 'etc/phrog/greetd-config.toml').write_text('[terminal]\nvt=7\n')
            with self.assertRaisesRegex(ValueError, 'greeter not activated'):
                contracts.validate_cutout(root)

    def test_rejects_unreviewed_wrapper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.image(root)
            (root / 'usr/libexec/qqcandy-phosh/greeter').write_text('#!/bin/sh\nexit 0\n')
            with self.assertRaisesRegex(ValueError, 'modified native cutout wrapper'):
                contracts.validate_cutout(root)

    def test_accepted_panel_and_greeter_only_private_library(self):
        panel = json.loads((NATIVE / 'panels/oplus,qqcandy.json').read_text())
        self.assertEqual((panel['x-res'], panel['y-res']), (1080, 2412))
        self.assertEqual(panel['cutouts'][0]['path'], 'M 0,0 L 0,118 L 150,118 L 150,0 Z')
        config = tomllib.loads((NATIVE / 'greetd-config.toml').read_text())
        self.assertEqual(config['default_session']['user'], 'greetd')
        self.assertEqual(config['default_session']['command'], '/usr/libexec/qqcandy-phosh/greeter')
        self.assertNotIn('LD_LIBRARY_PATH', (NATIVE / 'shell').read_text())

    def test_stock_version_format_and_safe_upgrade_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mappings = {
                '/usr/libexec/phosh': root / 'stock-phosh',
                '/usr/bin/phrog': root / 'stock-phrog',
                '/usr/lib/qqcandy-phosh': root / 'private',
                '/usr/libexec/phrog-greetd-session': root / 'session',
            }
            (root / 'private').mkdir()
            (root / 'private/phosh').write_text('#!/bin/sh\necho private-shell\n')
            (root / 'session').write_text('#!/bin/sh\necho "library=${LD_LIBRARY_PATH-unset}"\n')
            (root / 'stock-phrog').write_text('#!/bin/sh\necho "phrog 0.53.0"\n')
            scripts = {}
            for role in ('shell', 'greeter'):
                text = (NATIVE / role).read_text()
                for original, target in mappings.items():
                    text = text.replace(original, str(target))
                scripts[role] = root / role
                scripts[role].write_text(text)
            env = dict(os.environ)
            env.pop('LD_LIBRARY_PATH', None)
            for version, private in [('0.57.0', True), ('0.58.0', False)]:
                (root / 'stock-phosh').write_text(
                    '#!/bin/sh\nif [ "${1-}" = --version ]; then\n'
                    f'echo "Phosh {version} - A Wayland shell for mobile devices"\n'
                    'else echo stock-shell; fi\n')
                for path in root.rglob('*'):
                    if path.is_file(): path.chmod(0o755)
                shell = subprocess.check_output(['sh', str(scripts['shell'])], env=env, text=True)
                greeter = subprocess.check_output(['sh', str(scripts['greeter'])], env=env, text=True)
                self.assertEqual(shell.strip(), 'private-shell' if private else 'stock-shell')
                self.assertEqual(greeter.strip(), 'library=' + str(root / 'private') if private else 'library=unset')

    def test_builder_is_native_source_only_and_preserves_distribution_abi(self):
        script = (HERE / 'tools/install-phosh-cutout.sh').read_text()
        self.assertIn('sha512sum --check', script)
        self.assertIn('--suite unit', script)
        self.assertIn('stock.symbols', script)
        self.assertIn('preserving a different administrator greeter configuration', script)
        self.assertNotIn('fastboot', script)
        self.assertNotIn('LIBVA_DRIVER_NAME', script)
        qemu = (HERE / 'tools/with-qemu.sh').read_text()
        self.assertIn('--user --map-users', qemu)
        self.assertIn('mount -t binfmt_misc', qemu)


if __name__ == '__main__':
    unittest.main()
