import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).parents[1]


class UIDefaultsTests(unittest.TestCase):
    def test_app_visibility_override_compiles_and_is_not_a_console_overlay(self):
        override = HERE / "ui/phosh/qqcandy/usr/share/glib-2.0/schemas/90_qqcandy-apps.gschema.override"
        self.assertFalse((HERE / "overlay/qqcandy" / override.name).exists())
        self.assertFalse((HERE / "ui/console/qqcandy").exists())
        self.assertIn('apply_overlay "$HERE/ui/$UI/$DEVICE" "$ROOTFS"',
                      (HERE / "build.sh").read_text())
        if not shutil.which("glib-compile-schemas") or not shutil.which("gsettings"):
            self.skipTest("GLib tools not installed")
        with tempfile.TemporaryDirectory() as directory:
            schema_dir = Path(directory)
            (schema_dir / "sm.puri.phosh.gschema.xml").write_text("""<schemalist>
              <flags id="sm.puri.phosh.AppFilterModeFlags">
                <value nick="adaptive" value="1"/>
              </flags>
              <schema id="sm.puri.phosh" path="/sm/puri/phosh/">
                <key name="app-filter-mode" flags="sm.puri.phosh.AppFilterModeFlags">
                  <default>['adaptive']</default>
                </key>
              </schema>
            </schemalist>""")
            shutil.copyfile(override, schema_dir / override.name)
            subprocess.run(["glib-compile-schemas", "--strict", directory], check=True)
            env = dict(os.environ, GSETTINGS_SCHEMA_DIR=directory, GSETTINGS_BACKEND="memory")
            result = subprocess.check_output(
                ["gsettings", "get", "sm.puri.phosh", "app-filter-mode"], env=env, text=True)
            self.assertEqual(result.strip(), "@as []")


if __name__ == "__main__":
    unittest.main()
