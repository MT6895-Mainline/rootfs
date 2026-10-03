import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("import_modules", HERE / "tools/import-modules.py")
modules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(modules)


def fixture(parent, release="6.18.0+", machine=183):
    source = Path(parent) / release
    source.mkdir()
    header = bytearray(20)
    header[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<HH", header, 16, 1, machine)
    (source / "driver.ko").write_bytes(header)
    return source


class UserspaceTests(unittest.TestCase):
    def test_no_boot_build_or_workflow_checkout(self):
        builder = (HERE / "build.sh").read_text()
        workflow = (HERE / ".github/workflows/rootfs.yml").read_text()
        for value in ("make modules", 'make -j"$JOBS"', "kernel_git", "KBOUT", "KERNEL-INFO", "INITRAMFS_SOURCE"):
            self.assertNotIn(value, builder)
        self.assertNotIn("MT6895-Mainline/linux", workflow)
        self.assertNotIn("matrix.kernel", workflow)
        self.assertNotIn("gcc-aarch64-linux-gnu", workflow)
        self.assertIn("USERSPACE-INFO", builder)
        self.assertIn("MAKE_IMAGE=1", builder)
        self.assertFalse((HERE / "tools/prepare-initramfs.sh").exists())

    def test_removed_options_fail_before_network(self):
        for flag in ("--kernel-repo", "--kernel-ref", "--initramfs-ref"):
            result = subprocess.run(["bash", str(HERE / "build.sh"), flag, "unused"],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("was removed", result.stderr)

    def test_external_module_release_and_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            source = fixture(directory)
            with patch.object(modules.subprocess, "check_output", return_value="6.18.0+ SMP preempt\n"):
                record = modules.inspect(source, "6.18.0+")
            self.assertEqual(record["modules"], ["driver.ko"])
            self.assertFalse(record["hardware_validated"])
            self.assertFalse(record["symbol_versions_validated"])
            with patch.object(modules.subprocess, "check_output", return_value="6.18.0 SMP\n"):
                with self.assertRaisesRegex(ValueError, "release mismatch"):
                    modules.inspect(source, "6.18.0+")
            header = bytearray((source / "driver.ko").read_bytes())
            struct.pack_into("<H", header, 18, 62)
            (source / "driver.ko").write_bytes(header)
            with self.assertRaisesRegex(ValueError, "ARM64"):
                modules.inspect(source, "6.18.0+")

    def test_module_directory_and_links(self):
        with tempfile.TemporaryDirectory() as directory:
            source = fixture(directory)
            for value in ("../escape", "-bad", "none", "6.18.0"):
                with self.assertRaises(ValueError):
                    modules.inspect(source, value)
            (source / "build").symlink_to("/unavailable/build")
            with patch.object(modules.subprocess, "check_output", return_value="6.18.0+ SMP\n"):
                modules.inspect(source, "6.18.0+")
            (source / "escape.ko").symlink_to("/etc/passwd")
            with patch.object(modules.subprocess, "check_output", return_value="6.18.0+ SMP\n"):
                with self.assertRaisesRegex(ValueError, "symlink"):
                    modules.inspect(source, "6.18.0+")

    def test_mixed_vermagic_and_empty_source(self):
        with tempfile.TemporaryDirectory() as directory:
            source = fixture(directory)
            (source / "second.ko").write_bytes((source / "driver.ko").read_bytes())
            with patch.object(modules.subprocess, "check_output", side_effect=["6.18.0+ SMP", "6.18.0+ SMP modversions"]):
                with self.assertRaisesRegex(ValueError, "mixed module"):
                    modules.inspect(source, "6.18.0+")
            (source / "driver.ko").unlink()
            (source / "second.ko").unlink()
            with self.assertRaisesRegex(ValueError, "no .ko"):
                modules.inspect(source, "6.18.0+")

    def test_module_import_resolves_merged_usr_without_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            source = fixture(directory)
            root = Path(directory) / "root"
            (root / "usr/lib").mkdir(parents=True)
            (root / "lib").symlink_to("usr/lib")
            def depmod(args, **kwargs):
                (root / "usr/lib/modules/6.18.0+/modules.dep").touch()
            with patch.object(modules.subprocess, "check_output", return_value="6.18.0+ SMP\n"), \
                    patch.object(modules.subprocess, "run", side_effect=depmod):
                modules.install(root, source, "6.18.0+")
                with self.assertRaisesRegex(ValueError, "mix or replace"):
                    modules.install(root, source, "6.18.0+")
            self.assertEqual((root / "usr/lib/modules/6.18.0+/driver.ko").read_bytes(), (source / "driver.ko").read_bytes())
            self.assertTrue((root / "usr/share/mt6895-build/kernel-modules.json").is_file())
            with self.assertRaisesRegex(ValueError, "live host"):
                modules.install(Path("/"), source, "6.18.0+")


if __name__ == "__main__":
    unittest.main()
