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


if __name__ == "__main__":
    unittest.main()
