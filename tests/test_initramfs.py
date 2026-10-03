from pathlib import Path
import subprocess
import tempfile
import unittest


HERE = Path(__file__).parents[1]


class InitramfsTests(unittest.TestCase):
    def invoke(self, commit, device, output):
        return subprocess.run(["bash", str(HERE / "tools/prepare-initramfs.sh"),
                               "/not/a/repository", commit, device, str(output), ""],
                              capture_output=True, text=True)

    def test_reject_floating_or_shell_refs_before_network(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "out"
            for value in ("main", "latest", "a" * 39, "$(touch marker)"):
                result = self.invoke(value, "qqcandy", output)
                self.assertEqual(result.returncode, 2)
                self.assertIn("full commit ID", result.stderr)
                self.assertFalse(output.exists())

    def test_no_unreviewed_device_or_output_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "out"
            result = self.invoke("a" * 40, "xaga", output)
            self.assertEqual(result.returncode, 2)
            self.assertIn("reviewed", result.stderr)
            self.assertFalse(output.exists())
            output.mkdir()
            result = self.invoke("a" * 40, "qqcandy", output)
            self.assertEqual(result.returncode, 2)
            self.assertIn("already exists", result.stderr)

    def test_only_qqcandy_pins_embedded_contract(self):
        for file in (HERE / "devices").glob("*.conf"):
            text = file.read_text()
            self.assertEqual("INITRAMFS_COMMIT=" in text, file.stem == "qqcandy")

    def test_embedding_precedes_image_and_records_provenance(self):
        text = (HERE / "build.sh").read_text()
        self.assertLess(text.index("prepare pinned embedded initramfs"), text.index('log "2. build the kernel image"'))
        self.assertIn("--set-str INITRAMFS_SOURCE", text)
        self.assertNotIn("--enable INITRAMFS_FORCE", text)
        self.assertIn('initramfs:       $INITRAMFS_INFO', text)


if __name__ == "__main__":
    unittest.main()
