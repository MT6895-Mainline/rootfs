# qqcandy Phosh Cutout

The current Nura device has accepted desktop and Phrog greeter placement, login
and keyboard vibration. The AW8697 udev rule is in the qqcandy device overlay;
it adds feedbackd discovery and uaccess, not a new haptic driver.

Native layout rebuilding is currently limited to Nura Phosh 0.57.0 / Phrog
0.53.0. The builder verifies official source/Alpine-patch SHA512, retains the
Alpine patch, applies the tested top-bar change and runs native unit tests.
It compares libphosh exports with the stock ABI before activating private files.
Image contracts reject non-AArch64 files, changed wrappers/panel data and missing
desktop/greeter activation. Both automatic and explicit builds require them.
No kernel or boot is built. `--phosh-cutout off` retains the stock layout.

The [official Phosh method](https://phosh.mobi/posts/notch-support/) supplies
matching gmobile JSON through G_RESOURCE_OVERLAYS. The 1080x2412 panel uses the
150x118 safe rectangle derived from qqcandy's official Android 22801 resolution
overlay; it is not a measured circular camera contour. Native portrait height
is ceil(118/scale), at least the stock 32 logical pixels. Reserved app space and
drag/exclusive regions follow the same height. Landscape retains stock height;
full rotation acceptance and other distro versions are not claimed.

WORKAROUND: a private static Phosh shell and libphosh avoid modifying APK-owned
files. Only the greeter receives LD_LIBRARY_PATH. Package version drift falls
back to stock until reviewed rebuilding, prioritizing login over exact geometry.
Remove the local Shell.desktop override, restore the saved original greeter
TOML and remove private wrappers/files to return to stock, while logged out.
Replace this integration with distribution/upstream patches when available.

The Phosh patch is GPL-3.0-or-later, matching the original source files. Panel
data and wrappers are separate from proprietary firmware/NV. Build success
and unit tests are not whole-image phone acceptance.
