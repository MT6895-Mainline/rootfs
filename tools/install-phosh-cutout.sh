#!/usr/bin/env bash
# Rebuild the exact Nura Phosh source tested on qqcandy; keep APK files intact.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="" DEVICE="" DISTRO="" JOBS=2 CACHE=""
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
while [ $# -gt 0 ]; do
	case "$1" in
		--root) ROOTFS="${2:?}"; shift 2 ;;
		--device) DEVICE="${2:?}"; shift 2 ;;
		--distro) DISTRO="${2:?}"; shift 2 ;;
		--jobs) JOBS="${2:?}"; shift 2 ;;
		--source-cache) CACHE="${2:?}"; shift 2 ;;
		*) die "unknown argument: $1" ;;
	esac
done
[ "$DEVICE" = qqcandy ] && [ "$DISTRO" = nura ] || die 'native cutout integration is reviewed for qqcandy/Nura only'
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die 'invalid jobs'
[ "$(id -u)" = 0 ] && [ -d "$ROOTFS" ] || die 'root and an offline rootfs required'
ROOTFS="$(realpath "$ROOTFS")"
[ "$ROOTFS" != / ] || die 'refusing to rebuild a running desktop'
for path in usr/src usr/lib/qqcandy-phosh usr/libexec/qqcandy-phosh \
	usr/local/share/applications usr/share/qqcandy-phosh etc/phrog; do
	[[ "$(realpath -m "$ROOTFS/$path")" = "$ROOTFS/"* ]] || die 'target symlink escapes image'
done
. "$HERE/distros/nura.sh"
case "$(distro_chroot "$ROOTFS" /usr/libexec/phosh --version)" in
	'Phosh 0.57.0 - '*) ;;
	*) die 'unreviewed Phosh version' ;;
esac
[ "$(distro_chroot "$ROOTFS" /usr/bin/phrog --version)" = 'phrog 0.53.0' ] || die 'unreviewed Phrog version'
python3 - "$ROOTFS" <<'PY'
from pathlib import Path
import sys, tomllib
root = Path(sys.argv[1])
config = tomllib.loads((root / 'etc/phrog/greetd-config.toml').read_text())
expected = {'terminal': {'vt': 7}, 'default_session': {
    'command': '/usr/libexec/phrog-greetd-session', 'user': 'greetd'}}
if config != expected:
    raise SystemExit('preserving a different administrator greeter configuration')
if (root / 'usr/lib/qqcandy-phosh').exists():
    raise SystemExit('private cutout installation already exists; preserving it')
PY
TEMP="$(mktemp -d)"
install -d "$ROOTFS/usr/src"
SOURCE="$(mktemp -d "$ROOTFS/usr/src/.qqcandy-phosh.XXXXXX")"
TARGET="${SOURCE#"$ROOTFS"}"
DEPS=0 DNS=0
cleanup() {
	[ "$DEPS" = 0 ] || distro_chroot "$ROOTFS" apk del .qqcandy-phosh-build || true
	if [ "$DNS" = 1 ]; then
		rm -f "$ROOTFS/etc/resolv.conf"
		[ ! -e "$TEMP/resolv.conf" ] && [ ! -L "$TEMP/resolv.conf" ] || mv "$TEMP/resolv.conf" "$ROOTFS/etc/resolv.conf"
	fi
	rm -rf -- "$TEMP" "$SOURCE"
}
trap cleanup EXIT
fetch() {
	local name="$1" digest="$2" url="$3"
	if [ -n "$CACHE" ] && [ -f "$CACHE/$name" ]; then
		cp "$CACHE/$name" "$TEMP/$name"
	else
		curl --fail --location --retry 3 --output "$TEMP/$name" "$url"
	fi
	printf '%s  %s\n' "$digest" "$TEMP/$name" | sha512sum --check
}
fetch phosh-0.57.0.tar.xz \
	51219a3295b061047765368a0f65a02b131c4b229ec03713f547595b73a98c51b99086769bf0584dd7d44b8426b21d50162e76e955fb7a37a5136cefa253fea8 \
	https://sources.phosh.mobi/releases/phosh/phosh-0.57.0.tar.xz
fetch phosh-alpine-splash.patch \
	cb4bad612e5d2dff156c6b97b460c16ab7fd48067935b616fe0b65d11c3d255f1ecd06b800c654ac9ea93bc53e823eb47134836dfdf61bb338588dab78d3b9e9 \
	https://gitlab.alpinelinux.org/alpine/aports/-/raw/97dba23dc382440e73c3813c9072a25099fb0d67/community/phosh/splash-timeout-flatpak-dbus.patch
tar -xf "$TEMP/phosh-0.57.0.tar.xz" -C "$SOURCE"
git -C "$SOURCE/phosh-0.57.0" apply "$TEMP/phosh-alpine-splash.patch"
git -C "$SOURCE/phosh-0.57.0" apply "$HERE/ui/phosh/patches/0001-top-bar-cutout-height.patch"
if [ -e "$ROOTFS/etc/resolv.conf" ] || [ -L "$ROOTFS/etc/resolv.conf" ]; then
	cp -a "$ROOTFS/etc/resolv.conf" "$TEMP/resolv.conf"
fi
DNS=1
rm -f "$ROOTFS/etc/resolv.conf"
install -m 0644 /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
DEPS=1
distro_chroot "$ROOTFS" apk add --no-interactive --virtual .qqcandy-phosh-build \
	build-base appstream-dev callaudiod-dev elogind-dev evince-dev evolution-data-server-dev \
	feedbackd-dev gcr-dev gettext-dev glib-dev gmobile-dev gnome-bluetooth-dev gnome-desktop-dev \
	gtk+3.0-dev libadwaita-dev libgudev-dev libhandy1-dev libsecret-dev linux-pam-dev meson \
	modemmanager-dev networkmanager-dev polkit-elogind-dev pulseaudio-dev py3-docutils \
	qrcodegen-dev upower-dev wayland-dev wayland-protocols xvfb-run xmlstarlet
distro_chroot "$ROOTFS" meson setup "$TARGET/build" "$TARGET/phosh-0.57.0" \
	--prefix=/usr --libdir=lib --libexecdir=libexec --buildtype=debugoptimized \
	-Dauto_features=disabled -Dphoc_tests=disabled -Dman=false -Dintrospection=false \
	-Dbindings-lib=false -Dtests=true
distro_chroot "$ROOTFS" meson compile -C "$TARGET/build" -j "$JOBS"
distro_chroot "$ROOTFS" xvfb-run -a meson test -C "$TARGET/build" --suite unit --print-errorlogs --num-processes 2
distro_chroot "$ROOTFS" "$TARGET/build/src/phosh" --version
nm -D --defined-only "$ROOTFS/usr/lib/libphosh-0.45.so.0" | awk '{print $3}' | sort > "$TEMP/stock.symbols"
nm -D --defined-only "$SOURCE/build/src/libphosh-0.45.so.0" | awk '{print $3}' | sort > "$TEMP/private.symbols"
cmp "$TEMP/stock.symbols" "$TEMP/private.symbols" || die 'private libphosh exports differ from stock ABI'
install -d "$ROOTFS/usr/lib/qqcandy-phosh" "$ROOTFS/usr/libexec/qqcandy-phosh" \
	"$ROOTFS/usr/share/qqcandy-phosh/panels" "$ROOTFS/usr/local/share/applications" \
	"$ROOTFS/usr/share/mt6895-build"
install -m 0755 "$SOURCE/build/src/phosh" "$ROOTFS/usr/lib/qqcandy-phosh/phosh"
install -m 0755 "$SOURCE/build/src/libphosh-0.45.so.0" "$ROOTFS/usr/lib/qqcandy-phosh/libphosh-0.45.so.0"
for name in shell greeter; do
	install -m 0755 "$HERE/ui/phosh/qqcandy-native/$name" "$ROOTFS/usr/libexec/qqcandy-phosh/$name"
done
install -m 0644 "$HERE/ui/phosh/qqcandy-native/panels/oplus,qqcandy.json" "$ROOTFS/usr/share/qqcandy-phosh/panels/oplus,qqcandy.json"
sed 's|^Exec=.*|Exec=/usr/libexec/qqcandy-phosh/shell|' \
	"$ROOTFS/usr/share/applications/mobi.phosh.Shell.desktop" > \
	"$ROOTFS/usr/local/share/applications/mobi.phosh.Shell.desktop"
install -m 0644 "$ROOTFS/etc/phrog/greetd-config.toml" "$ROOTFS/usr/share/qqcandy-phosh/original-greetd-config.toml"
install -m 0644 "$HERE/ui/phosh/qqcandy-native/greetd-config.toml" "$ROOTFS/etc/phrog/greetd-config.toml"
python3 - "$ROOTFS" "$HERE" <<'PY'
import hashlib, json
from pathlib import Path
import sys
root, here = map(Path, sys.argv[1:])
info = {'schema': 1, 'device': 'qqcandy', 'distro': 'nura', 'phosh_version': '0.57.0',
        'phrog_version': '0.53.0', 'hardware_validated': False,
        'patch_sha256': hashlib.sha256((here / 'ui/phosh/patches/0001-top-bar-cutout-height.patch').read_bytes()).hexdigest()}
(root / 'usr/share/mt6895-build/phosh-cutout.json').write_text(json.dumps(info, indent=2) + '\n')
PY
distro_chroot "$ROOTFS" env LD_LIBRARY_PATH=/usr/lib/qqcandy-phosh /usr/bin/phrog --version
python3 - "$HERE" "$ROOTFS" <<'PY'
import importlib.util
from pathlib import Path
import sys
here, root = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('image_contracts', here / 'tools/validate-rootfs.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.validate_cutout(root)
PY
printf '%s\n' 'Private Phosh cutout integration installed; stock APK binaries and library unchanged'
