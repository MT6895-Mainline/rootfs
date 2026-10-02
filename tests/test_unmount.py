import importlib.util
import pathlib
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / "tools/unmount-tree.py"
spec = importlib.util.spec_from_file_location("unmount", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MountTests(unittest.TestCase):
    def test_owned_tree_only_and_children_first(self):
        root = pathlib.Path("/tmp/a b/.work-1/pmb-work")
        paths = [str(root) + "/root/dev", "/", str(root) + "/root/dev/pts",
                 str(root) + "-other/dev", "/tmp/other/pmb-work/root/dev"]
        result = module.targets({"filesystems": [{"target": p} for p in paths]}, root)
        self.assertEqual(result, [paths[2], paths[0]])
