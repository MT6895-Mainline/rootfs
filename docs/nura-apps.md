# Nura Phosh Applications

The Nura backend installs the official Phosh UI and all recommendations from
its four recipe layers. It does not substitute a hand-picked minimal app set.
The source pin is pmaports `5f7529d92dcc1c41b2bfb6a7b3e09df8fafc0a34`.

## Official Sources

- [Phosh UI](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/blob/5f7529d92dcc1c41b2bfb6a7b3e09df8fafc0a34/main/postmarketos-ui-phosh/APKBUILD)
- [GNOME Mobile base](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/blob/5f7529d92dcc1c41b2bfb6a7b3e09df8fafc0a34/main/postmarketos-base-ui-gnome-mobile/APKBUILD)
- [GNOME base](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/blob/5f7529d92dcc1c41b2bfb6a7b3e09df8fafc0a34/main/postmarketos-base-ui-gnome/APKBUILD)
- [UI base](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/blob/5f7529d92dcc1c41b2bfb6a7b3e09df8fafc0a34/main/postmarketos-base-ui/APKBUILD)

Installing the meta packages through `apk add` does not expand the
pmbootstrap-specific `_pmb_recommends`. `distros/nura.sh` therefore explicitly
installs the complete union below, in addition to the meta packages and their
normal dependencies. The build records the pin and list in
`/usr/share/mt6895-build/nura-phosh-recommends.txt`.

## Complete Recommendations

Phosh UI (2):

```text
phosh-mobile-settings phosh-tour
```

GNOME Mobile base (7):

```text
calls chatty lpa-gtk mobile-config-firefox
postmarketos-tweaks-setting-definitions ttyescape vvmplayer
```

GNOME base (27):

```text
cups decibels firefox-esr flatpak fprintd g4music
gnome-calculator gnome-calendar gnome-clocks gnome-console gnome-contacts
gnome-maps gnome-text-editor gnome-user-share gnome-weather
gst-libav gst-plugins-bad gst-plugins-good gst-plugins-rs-dav1d gvfs-full
loupe nautilus papers rygel showtime snapshot tuned-ppd
```

UI base (4):

```text
font-droid font-droid-nonlatin font-twemoji lang
```

These are 40 recommendation packages, not 40 graphical applications. Fonts,
languages, multimedia plugins and services are deliberately retained.
`stevia-schemas` is also installed explicitly: the current Stevia main package
does not depend on its split settings schema, which is required by the OSK.

## Verification Boundary

At rootfs commit `1495876`, Nura, Arch and Mobian complete userspace builds passed
[CI](https://github.com/MT6895-Mainline/rootfs/actions/runs/37124423466).
On the qqcandy Nura test system, all 40 recommendations passed package-presence
checks, 17 main desktop entries passed Gio visibility/executable checks, and
Contacts and Text Editor activated on the existing desktop session.
Gio checks alone do not prove visibility in Phosh's adaptive-only app grid.
qqcandy Phosh builds now set `app-filter-mode=[]` in a UI-specific GSettings
override and validate that default with the target's GLib tools. Console builds
do not install the override. Existing users' explicit preferences are retained.

Installed Calls, Chatty, Camera, LPA or fingerprint service packages do not
prove modem, camera, eSIM or fingerprint hardware support. No incompatible
fingerprint driver or device tree is added. Extra service packages are not
indiscriminately enabled; modem startup remains separately gated.
