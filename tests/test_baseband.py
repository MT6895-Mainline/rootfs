import importlib.util
import configparser
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validator = load("baseband_validator", HERE / "tools/validate-rootfs.py")
gate = load("ready_gate", HERE / "baseband/wait-ready.py")


class BasebandTests(unittest.TestCase):
    def installer_fixture(self, directory):
        project = directory / "project"
        for subdir in ("tools", "devices", "distros", "bin"):
            (project / subdir).mkdir(parents=True)
        for name in ("install-baseband.sh", "validate-rootfs.py"):
            shutil.copyfile(HERE / "tools" / name, project / "tools" / name)
        (project / "devices/qqcandy.conf").write_text(
            "BASEBAND_OWNER_REPO=unused BASEBAND_MM_REPO=unused\n"
            "BASEBAND_OWNER_BRANCH=main BASEBAND_MM_BRANCH=main\n")
        (project / "distros/mobian.sh").write_text(
            "BASEBAND_BUILD_PACKAGES=unused\n"
            "distro_install_packages() { return 42; }\n"
            "distro_chroot() { return 43; }\n")
        mocks = {
            "id": "#!/bin/bash\nprintf '0\\n'\n",
            "git": """#!/bin/bash
case "$*" in
  clone*) mkdir -p "${@: -1}" ;;
  *rev-parse*) printf '%040d\\n' 1 ;;
  *archive*) tar -cf - --files-from /dev/null ;;
  *checkout*) ;;
  *) exit 44 ;;
esac
""",
        }
        for name, contents in mocks.items():
            path = project / "bin" / name
            path.write_text(contents)
            path.chmod(0o755)
        root = directory / "root"
        (root / "sbin").mkdir(parents=True)
        header = bytearray(20)
        header[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", header, 18, 183)
        (root / "sbin/init").write_bytes(header)
        (root / "etc").mkdir()
        environment = dict(os.environ, PATH=str(project / "bin") + ":" + os.environ["PATH"])
        command = ["bash", str(project / "tools/install-baseband.sh"), "--root", str(root),
                   "--device", "qqcandy", "--distro", "mobian"]
        return root, command, environment

    def fixture(self, root, distro="mobian"):
        manifest = {"schema": 1, "device": "qqcandy", "distro": distro,
                    "owner_commit": "a" * 40, "mm_commit": "b" * 40,
                    "autostart": False, "hardware_validated": False}
        release = "a" * 40 + "-" + "b" * 40
        bundle = root / "usr/lib/mtk-ccci/releases" / release
        bundle.mkdir(parents=True)
        (bundle.parent.parent / "current").symlink_to("releases/" + release)
        info = root / "usr/share/mt6895-build/baseband.json"
        info.parent.mkdir(parents=True)
        info.write_text(json.dumps(manifest))
        (bundle / "manifest.json").write_text(json.dumps(manifest))
        header = bytearray(20)
        header[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", header, 18, 183)
        for name in ("mm/sbin/ModemManager", "mm/lib/ModemManager/libmm-plugin-mtk-soc.so"):
            file = bundle / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(header)
        for name in ("owner/libexec/mtk-ccci/start_owner.py", "owner/libexec/mtk-ccci/mdinit.py",
                     "mm/lib/libmm-glib.so.0"):
            file = bundle / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.touch()
        for name in ("ModemManager", "start-owner", "wait-ready.py", "prepare-owner.py", "run-limited.py"):
            file = root / "usr/libexec/mtk-ccci" / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.touch(mode=0o755)
        rule = root / "etc/udev/rules.d/77-mm-mtk-soc.rules"
        rule.parent.mkdir(parents=True)
        rule.touch()
        for service in ("mtk-ccci-prepare", "mtk-ccci-owner", "mtk-modemmanager"):
            unit = (root / "etc/init.d" / service if distro == "nura" else
                    root / "usr/lib/systemd/system" / (service + ".service"))
            unit.parent.mkdir(parents=True, exist_ok=True)
            unit.touch(mode=0o755 if distro == "nura" else 0o644)
        return bundle, info, manifest

    def test_installed_bundle_and_pre_promotion_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle, _, _ = self.fixture(root)
            validator.validate_baseband(root)
            (root / "usr/lib/mtk-ccci/current").unlink()
            validator.validate_baseband(root, "/" + str(bundle.relative_to(root)))

    def test_reject_floating_refs_and_unverified_boot_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, info, manifest = self.fixture(root)
            for field, value in (("owner_commit", "main"), ("mm_commit", 123),
                                 ("autostart", True), ("hardware_validated", True)):
                broken = dict(manifest, **{field: value})
                info.write_text(json.dumps(broken))
                with self.assertRaises(ValueError):
                    validator.validate_baseband(root)

    def test_reject_mismatched_bundle_and_wrong_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle, _, manifest = self.fixture(root)
            (bundle / "manifest.json").write_text(json.dumps(dict(manifest, distro="arch")))
            with self.assertRaisesRegex(ValueError, "manifest mismatch"):
                validator.validate_baseband(root)
            (bundle / "manifest.json").write_text(json.dumps(manifest))
            daemon = bundle / "mm/sbin/ModemManager"
            header = bytearray(daemon.read_bytes())
            struct.pack_into("<H", header, 18, 62)
            daemon.write_bytes(header)
            with self.assertRaisesRegex(ValueError, "not AArch64"):
                validator.validate_baseband(root)

    def test_unvalidated_service_must_not_be_enabled(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            unit = root / "usr/lib/systemd/system/mtk-ccci-owner.service"
            wants = root / "etc/systemd/system/multi-user.target.wants"
            wants.mkdir(parents=True)
            (wants / unit.name).symlink_to("/usr/lib/systemd/system/" + unit.name)
            with self.assertRaisesRegex(ValueError, "automatically enabled"):
                validator.validate_baseband(root)

    def test_runtime_services_must_be_installed(self):
        for distro in ("mobian", "nura"):
            with self.subTest(distro=distro), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root, distro)
                validator.validate_baseband(root)
                unit = (root / "etc/init.d/mtk-ccci-owner" if distro == "nura" else
                        root / "usr/lib/systemd/system/mtk-ccci-owner.service")
                unit.unlink()
                with self.assertRaisesRegex(ValueError, "missing.*baseband service"):
                    validator.validate_baseband(root)

    def test_openrc_boot_runlevel_must_not_enable_unvalidated_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, "nura")
            boot = root / "etc/runlevels/boot"
            boot.mkdir(parents=True)
            (boot / "mtk-ccci-owner").symlink_to("/etc/init.d/mtk-ccci-owner")
            with self.assertRaisesRegex(ValueError, "automatically enabled"):
                validator.validate_baseband(root)

    def test_ready_gate_does_not_accept_idle_and_has_a_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "boot"
            state.write_text("md1:4 | READY")
            gate.wait_ready(state, 1)
            state.write_text("md1:0")
            with patch.object(gate.time, "monotonic", side_effect=[0, 2]):
                with self.assertRaisesRegex(RuntimeError, "did not reach READY"):
                    gate.wait_ready(state, 1)

    def test_private_unit_does_not_allocate_distribution_dbus_name(self):
        unit = configparser.ConfigParser(interpolation=None)
        unit.read(HERE / "baseband/mtk-modemmanager.service")
        self.assertEqual(unit["Service"]["Type"], "exec")
        self.assertNotIn("BusName", unit["Service"])
        self.assertIn("ModemManager.service", unit["Unit"]["Conflicts"].split())
        self.assertIn("ModemManager.service", unit["Unit"]["After"].split())
        self.assertGreater(int(unit["Service"]["TimeoutStartSec"]), 120)

    def test_installer_rejects_floating_shell_refs_before_network(self):
        result = subprocess.run(["bash", str(HERE / "tools/install-baseband.sh"),
                                 "--device", "qqcandy", "--distro", "mobian",
                                 "--owner-ref", "$(touch unwanted)"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("full commit IDs", result.stderr)

    def test_package_failure_restores_dns_and_previous_selection(self):
        # Mock only source fetching/package execution; run the actual cleanup code.
        for original in ("symlink", "regular", "absent"):
            with self.subTest(original=original), tempfile.TemporaryDirectory() as directory:
                root, command, environment = self.installer_fixture(Path(directory))
                dns = root / "etc/resolv.conf"
                if original == "symlink":
                    dns.symlink_to("/run/NetworkManager/resolv.conf")
                elif original == "regular":
                    dns.write_text("nameserver 192.0.2.1\n")
                    dns.chmod(0o600)
                base = root / "usr/lib/mtk-ccci"
                base.mkdir(parents=True)
                (base / "current").symlink_to("releases/previous")
                result = subprocess.run(command, env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertEqual(os.readlink(base / "current"), "releases/previous")
                self.assertFalse((base / "releases").exists())
                self.assertEqual(list((root / "usr/src").glob(".mtk-ccci.*")), [])
                if original == "symlink":
                    self.assertEqual(os.readlink(dns), "/run/NetworkManager/resolv.conf")
                elif original == "regular":
                    self.assertEqual(dns.read_text(), "nameserver 192.0.2.1\n")
                    self.assertEqual(dns.stat().st_mode & 0o777, 0o600)
                else:
                    self.assertFalse(dns.exists() or dns.is_symlink())

    def test_invalid_cached_bundle_does_not_switch_previous_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root, command, environment = self.installer_fixture(Path(directory))
            _, info, manifest = self.fixture(root)
            info.write_text(json.dumps(manifest))
            base = root / "usr/lib/mtk-ccci"
            previous = os.readlink(base / "current")
            release = "0" * 39 + "1"
            corrupt = base / "releases" / (release + "-" + release)
            corrupt.mkdir()
            (corrupt / "manifest.json").write_text("{}")
            result = subprocess.run(command, env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid baseband installation", result.stderr)
            self.assertEqual(os.readlink(base / "current"), previous)
            self.assertEqual(json.loads(info.read_text()), manifest)


if __name__ == "__main__":
    unittest.main()
