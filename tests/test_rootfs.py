import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "rootfs_validator", Path(__file__).parents[1] / "tools/validate-rootfs.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class RootfsTest(unittest.TestCase):
    def test_absolute_and_relative_target_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "usr/bin").mkdir(parents=True)
            (root / "bin").symlink_to("usr/bin")
            (root / "init").symlink_to("/bin/init")
            self.assertEqual(validator.rooted(root, "/init"), root / "usr/bin/init")

    def test_symlink_escape_and_loop(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "escape").symlink_to("../outside")
            (root / "loop").symlink_to("loop")
            for name in ("escape", "loop"):
                with self.assertRaises(ValueError):
                    validator.rooted(root, name)

    def test_aarch64_header_and_wrong_machine(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "driver.so"
            header = bytearray(20)
            header[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", header, 18, 183)
            path.write_bytes(header)
            validator.aarch64(path)
            struct.pack_into("<H", header, 18, 62)
            path.write_bytes(header)
            with self.assertRaises(ValueError):
                validator.aarch64(path)

    def test_display_manager_alias_and_broken_unit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "etc/systemd/system").mkdir(parents=True)
            (root / "usr/lib/systemd/system").mkdir(parents=True)
            unit = root / "usr/lib/systemd/system/gdm.service"
            unit.write_text("[Install]\nAlias=display-manager.service\n")
            (root / "etc/systemd/system/display-manager.service").symlink_to(
                "/usr/lib/systemd/system/gdm.service")
            self.assertTrue(validator.enabled(root, "gdm.service"))
            self.assertFalse(validator.enabled(root, "greetd.service"))
            unit.unlink()
            self.assertFalse(validator.enabled(root, "gdm.service"))

    def test_gdm_requires_phosh_wayland_session(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sessions = root / "usr/share/wayland-sessions"
            sessions.mkdir(parents=True)
            (sessions / "phosh.desktop").touch()
            users = root / "var/lib/AccountsService/users"
            users.mkdir(parents=True)
            config = users / "mobian"
            config.write_text("[User]\nSession=phosh\nSessionType=wayland\n")
            validator.validate_gdm(root, "mobian")
            config.write_text("[User]\nSession=gnome\nSessionType=wayland\n")
            with self.assertRaises(ValueError):
                validator.validate_gdm(root, "mobian")
            config.write_text("[User]\nSession=phosh\nSessionType=x11\n")
            with self.assertRaises(ValueError):
                validator.validate_gdm(root, "mobian")

    def test_required_kernel_modules_and_compression(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "ccci_md_all.ko.zst").touch()
            (root / "ccci_ccif.ko").touch()
            validator.require_modules(root, ["ccci_md_all", "ccci_ccif"])
            with self.assertRaisesRegex(ValueError, "ccci_dpmaif"):
                validator.require_modules(root, ["ccci_dpmaif"])


if __name__ == "__main__":
    unittest.main()
