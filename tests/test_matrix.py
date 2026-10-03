import importlib.util
import pathlib
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / "tools/matrix.py"
spec = importlib.util.spec_from_file_location("matrix", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MatrixTests(unittest.TestCase):
    def test_three_distros(self):
        result = module.matrix("qqcandy", "mobian arch nura")["include"]
        self.assertEqual(len(result), 3)
        self.assertEqual({r["distro"] for r in result}, {"mobian", "arch", "nura"})
        self.assertTrue(all("kernel" not in entry for entry in result))

    def test_legacy_variant_uses_real_profile(self):
        entry = module.matrix("xaga-6.18", "arch")["include"][0]
        self.assertEqual(entry["device"], "xaga")
        self.assertEqual(entry["suffix"], "-6.18")

    def test_reject_inputs(self):
        for devices, distros in [("", "arch"), ("qqcandy", ""), ("$(id)", "arch"),
                                ("qqcandy", "../debian"), ("xaga xaga", "arch")]:
            with self.subTest(devices=devices, distros=distros), self.assertRaises(ValueError):
                module.matrix(devices, distros)
