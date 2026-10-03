import importlib.util
from pathlib import Path
import struct
import subprocess
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

    def test_greetd_display_manager_alias(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "etc/systemd/system").mkdir(parents=True)
            (root / "usr/lib/systemd/system").mkdir(parents=True)
            unit = root / "usr/lib/systemd/system/greetd.service"
            unit.write_text("[Install]\nAlias=display-manager.service\n")
            (root / "etc/systemd/system/display-manager.service").symlink_to(
                "/usr/lib/systemd/system/greetd.service")
            self.assertTrue(validator.enabled(root, "greetd.service"))
            self.assertFalse(validator.enabled(root, "gdm.service"))
            self.assertFalse(validator.enabled(root, "NetworkManager.service"))
            unit.unlink()
            self.assertFalse(validator.enabled(root, "greetd.service"))

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

    def test_openrc_identity_must_be_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "etc").mkdir()
            validator.validate_identity(root, "openrc")
            path = root / "etc/machine-id"
            for data in (b"", b"0123456789abcdef0123456789abcdef\n"):
                path.write_bytes(data)
                with self.assertRaisesRegex(ValueError, "OpenRC image must omit"):
                    validator.validate_identity(root, "openrc")

    def test_systemd_identity_must_be_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "etc").mkdir()
            path = root / "etc/machine-id"
            path.touch()
            validator.validate_identity(root, "systemd")
            for data in (b"\n", b"0123456789abcdef0123456789abcdef\n"):
                path.write_bytes(data)
                with self.assertRaisesRegex(ValueError, "systemd image must have an empty"):
                    validator.validate_identity(root, "systemd")

    def test_image_must_not_contain_dbus_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "etc").mkdir()
            directory = root / "var/lib/dbus"
            directory.mkdir(parents=True)
            path = directory / "machine-id"
            for data in (b"", b"0123456789abcdef0123456789abcdef\n"):
                path.write_bytes(data)
                with self.assertRaisesRegex(ValueError, "D-Bus machine identity"):
                    validator.validate_identity(root, "openrc")
            path.unlink()
            path.symlink_to("/nonexistent")
            with self.assertRaisesRegex(ValueError, "D-Bus machine identity"):
                validator.validate_identity(root, "openrc")

    def test_machine_id_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "etc").mkdir()
            (root / "etc/machine-id").symlink_to("/nonexistent")
            for init in ("openrc", "systemd"):
                with self.assertRaises(ValueError):
                    validator.validate_identity(root, init)

    def test_nura_finalize_removes_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("etc/systemd/system", "etc/ssh", "var/lib/dbus", "var/cache"):
                (root / name).mkdir(parents=True)
            (root / "etc/machine-id").touch()
            (root / "var/lib/dbus/machine-id").write_text("0123456789abcdef0123456789abcdef\n")
            backend = Path(__file__).parents[1] / "distros/nura.sh"
            subprocess.run(["bash", "-euc", '''
                source "$1"
                distro_chroot() { :; }
                distro_finalize "$2"
            ''', "bash", str(backend), str(root)], check=True)
            validator.validate_identity(root, "openrc")

    def test_openrc_identity_runs_before_dbus_even_after_firstboot(self):
        base = Path(__file__).parents[1] / "overlay/common"
        service = (base / "etc/init.d/mt6895-firstboot").read_text()
        self.assertIn("before dbus sshd greetd", service)
        self.assertNotIn("mt6895-firstboot-done", service)
        script = (base / "usr/local/sbin/mt6895-firstboot").read_text()
        self.assertLess(script.index("dbus-uuidgen"), script.index("mt6895-firstboot-done"))

    def test_phosh_needs_target_compiled_schemas(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schemas = root / "query.txt"
            schemas.write_text("sm.puri.phosh\n")
            validator.validate_phosh_schemas(root, schemas)
            with self.assertRaisesRegex(ValueError, "target gsettings"):
                validator.validate_phosh_schemas(root, None)
            schemas.write_text("sm.puri.phosh.lockscreen\n")
            with self.assertRaisesRegex(ValueError, "sm.puri.phosh"):
                validator.validate_phosh_schemas(root, schemas)

    def test_stevia_requires_its_runtime_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "usr/bin").mkdir(parents=True)
            (root / "usr/bin/phosh-osk-stevia").touch()
            schemas = root / "query.txt"
            schemas.write_text("sm.puri.phosh\n")
            with self.assertRaisesRegex(ValueError, "mobi.phosh.osk"):
                validator.validate_phosh_schemas(root, schemas)
            schemas.write_text("sm.puri.phosh\nmobi.phosh.osk\n")
            validator.validate_phosh_schemas(root, schemas)
            backend = (Path(__file__).parents[1] / "distros/nura.sh").read_text()
            self.assertIn("postmarketos-ui-phosh-openrc stevia-schemas", backend)

    def test_nura_official_phosh_recommendations_are_explicit(self):
        backend = Path(__file__).parents[1] / "distros/nura.sh"
        result = subprocess.run(["bash", "-euc", 'source "$1"; printf "%s" "$NURA_PHOSH_RECOMMENDS"',
                                 "bash", str(backend)], text=True, capture_output=True, check=True)
        packages = result.stdout.split()
        self.assertEqual(len(packages), len(set(packages)))
        expected = """phosh-mobile-settings phosh-tour calls chatty lpa-gtk mobile-config-firefox
            postmarketos-tweaks-setting-definitions ttyescape vvmplayer cups decibels firefox-esr
            flatpak fprintd g4music gnome-calculator gnome-calendar gnome-clocks gnome-console
            gnome-contacts gnome-maps gnome-text-editor gnome-user-share gnome-weather gst-libav
            gst-plugins-bad gst-plugins-good gst-plugins-rs-dav1d gvfs-full loupe nautilus papers
            rygel showtime snapshot tuned-ppd font-droid font-droid-nonlatin font-twemoji lang"""
        self.assertEqual(set(packages), set(expected.split()))
        self.assertIn("pmb chroot -r -- apk add $NURA_PHOSH_RECOMMENDS", backend.read_text())

    def test_wifi_filter_does_not_match_station_or_usb(self):
        file = Path(__file__).parents[1] / "overlay/qqcandy/etc/NetworkManager/conf.d/90-qqcandy-single-wifi.conf"
        text = file.read_text()
        self.assertIn("managed=0", text)
        self.assertNotIn("interface-name:wlan0", text)
        self.assertNotIn("interface-name:usb0", text)


if __name__ == "__main__":
    unittest.main()
