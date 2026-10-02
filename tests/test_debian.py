from pathlib import Path
import subprocess
import unittest


class DebianSourcesTest(unittest.TestCase):
    def sources(self, suite):
        backend = Path(__file__).parents[1] / "distros/debian.sh"
        script = '''
            source "$1"
            WORK=/unused
            debian_keyring() { :; }
            mmdebstrap() { printf '%s\\n' "$@"; }
            install() { :; }
            distro_bootstrap /unused "$2" arm64 https://deb.debian.org/debian
        '''
        return subprocess.check_output(
            ["bash", "-euc", script, "bash", str(backend), suite], text=True)

    def test_stable_security_and_updates(self):
        sources = self.sources("trixie")
        self.assertIn("trixie-security main contrib non-free-firmware", sources)
        self.assertIn("trixie-updates main contrib non-free-firmware", sources)
        self.assertIn("--keyring=/unused/debian-trust/archive.gpg", sources)

    def test_unstable_has_no_stable_security_suite(self):
        self.assertNotIn("sid-security", self.sources("sid"))


if __name__ == "__main__":
    unittest.main()
