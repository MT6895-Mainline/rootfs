#!/usr/bin/env bash
# Install a tested, versioned CCCI/MM bundle into an offline ARM64 rootfs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="" DEVICE="" DISTRO="" JOBS=2
OWNER_REF=latest MM_REF=latest
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
	printf '%s\n' 'Usage: install-baseband.sh --root DIR --device qqcandy --distro mobian|arch|nura' \
		'       [--owner-ref latest|COMMIT] [--mm-ref latest|COMMIT] [--jobs N]' \
		'Offline installation only; does not start services, load modules or write NV.'
}
while [ $# -gt 0 ]; do
	case "$1" in
		--root) ROOTFS="${2:?}"; shift 2 ;;
		--device) DEVICE="${2:?}"; shift 2 ;;
		--distro) DISTRO="${2:?}"; shift 2 ;;
		--owner-ref) OWNER_REF="${2:?}"; shift 2 ;;
		--mm-ref) MM_REF="${2:?}"; shift 2 ;;
		--jobs) JOBS="${2:?}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done
[ "$DEVICE" = qqcandy ] || die 'only qqcandy has a reviewed baseband profile'
[ "$DISTRO" != pmos ] || DISTRO=nura
case "$DISTRO" in mobian|debian|arch|nura) ;; *) die 'unsupported distribution' ;; esac
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die 'invalid jobs'
for ref in "$OWNER_REF" "$MM_REF"; do
	[[ "$ref" = latest || "$ref" =~ ^[0-9a-f]{40}$ ]] || die 'refs must be latest or full commit IDs'
done
[ "$(id -u)" = 0 ] || die 'offline rootfs installation requires root'
[ -n "$ROOTFS" ] || die '--root must be an existing offline rootfs'
[ -d "$ROOTFS" ] || die '--root must be an existing offline rootfs'
ROOTFS="$(realpath "$ROOTFS")"
[ "$ROOTFS" != / ] || die 'refusing to update a running system or modem'
for directory in usr/src usr/lib/mtk-ccci usr/libexec/mtk-ccci usr/share/mt6895-build \
	usr/lib/systemd/system etc/init.d etc/udev/rules.d; do
	[[ "$(realpath -m "$ROOTFS/$directory")" = "$ROOTFS/"* ]] || die 'target symlink escapes rootfs'
done
python3 - "$HERE" "$ROOTFS" <<'PY'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location("validate", Path(sys.argv[1]) / "tools/validate-rootfs.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.aarch64(module.rooted(Path(sys.argv[2]), "/sbin/init"))
PY
. "$HERE/devices/$DEVICE.conf"
. "$HERE/distros/$DISTRO.sh"
WORK="$(mktemp -d)"
install -d "$ROOTFS/usr/src" "$ROOTFS/usr/lib/mtk-ccci"
exec 9>"$ROOTFS/usr/lib/mtk-ccci/install.lock"
flock -n 9 || die 'another baseband installation is in progress'
SOURCE_DIR="$(mktemp -d "$ROOTFS/usr/src/.mtk-ccci.XXXXXX")"
RELEASE_CREATED=0
ACTIVATED=0
DNS_CHANGED=0
DNS_PRESENT=0
cleanup() {
	if [ "$RELEASE_CREATED" = 1 ] && [ "$ACTIVATED" = 0 ]; then
		rm -rf -- "$ROOTFS$PREFIX"
	fi
	if [ "$DNS_CHANGED" = 1 ]; then
		rm -f -- "$ROOTFS/etc/resolv.conf"
		[ "$DNS_PRESENT" = 0 ] || mv "$WORK/resolv.conf" "$ROOTFS/etc/resolv.conf"
	fi
	rm -rf -- "$SOURCE_DIR" "$WORK"
}
trap cleanup EXIT
TARGET_SOURCE="${SOURCE_DIR#"$ROOTFS"}"
resolve_source() {
	local repo="$1" ref="$2" branch="$3" dest="$4" commit
	git clone --filter=blob:none --no-checkout "$repo" "$dest" >&2
	[ "$ref" != latest ] || ref="origin/$branch"
	commit="$(git -C "$dest" rev-parse --verify "$ref^{commit}")"
	[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die 'invalid resolved source commit'
	git -C "$dest" checkout --detach "$commit" >&2
	printf '%s\n' "$commit"
}
OWNER_COMMIT="$(resolve_source "$BASEBAND_OWNER_REPO" "$OWNER_REF" "$BASEBAND_OWNER_BRANCH" "$WORK/owner")"
MM_COMMIT="$(resolve_source "$BASEBAND_MM_REPO" "$MM_REF" "$BASEBAND_MM_BRANCH" "$WORK/mm")"
RELEASE="${OWNER_COMMIT}-${MM_COMMIT}"
PREFIX="/usr/lib/mtk-ccci/releases/$RELEASE"
validate_bundle() {
	python3 - "$HERE" "$ROOTFS" "$PREFIX" <<'PY'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location("validate", Path(sys.argv[1]) / "tools/validate-rootfs.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.validate_baseband(Path(sys.argv[2]), sys.argv[3])
PY
}
check_versions() {
	distro_chroot "$ROOTFS" env "LD_LIBRARY_PATH=$PREFIX/mm/lib" "$PREFIX/mm/sbin/ModemManager" --version
	distro_chroot "$ROOTFS" python3 "$PREFIX/owner/libexec/mtk-ccci/start_owner.py" --version
}
select_bundle() {
	ln -s "releases/$RELEASE" "$ROOTFS/usr/lib/mtk-ccci/current.new"
	mv -Tf "$ROOTFS/usr/lib/mtk-ccci/current.new" "$ROOTFS/usr/lib/mtk-ccci/current"
	ACTIVATED=1
	install -m 0644 "$ROOTFS$PREFIX/manifest.json" "$ROOTFS/usr/share/mt6895-build/baseband.json"
}
install_integration() {
	local rule="$ROOTFS/etc/udev/rules.d/77-mm-mtk-soc.rules"
	if [ -e "$rule" ]; then
		cmp -s "$rule" "$WORK/mm/src/plugins/mtk-soc/77-mm-mtk-soc.rules" || die 'preserving a different existing MTK udev rule'
	else
		install -D -m 0644 "$WORK/mm/src/plugins/mtk-soc/77-mm-mtk-soc.rules" "$rule"
	fi
	install -d "$ROOTFS/usr/libexec/mtk-ccci" "$ROOTFS/usr/share/mt6895-build"
	install -m 0755 "$HERE/baseband/ModemManager" "$ROOTFS/usr/libexec/mtk-ccci/ModemManager"
	install -m 0755 "$HERE/baseband/start-owner" "$ROOTFS/usr/libexec/mtk-ccci/start-owner"
	install -m 0755 "$HERE/baseband/wait-ready.py" "$ROOTFS/usr/libexec/mtk-ccci/wait-ready.py"
	if [ "$INIT_SYSTEM" = systemd ]; then
		install -d "$ROOTFS/usr/lib/systemd/system"
		sed 's|^ExecStart=.*|ExecStart=/usr/libexec/mtk-ccci/start-owner|' \
			"$WORK/owner/systemd/mtk-ccci-owner.service.example" > \
			"$ROOTFS/usr/lib/systemd/system/mtk-ccci-owner.service"
		install -m 0644 "$HERE/baseband/mtk-modemmanager.service" "$ROOTFS/usr/lib/systemd/system/mtk-modemmanager.service"
	else
		install -d "$ROOTFS/etc/init.d"
		install -m 0755 "$HERE/baseband/mtk-ccci-owner.initd" "$ROOTFS/etc/init.d/mtk-ccci-owner"
		install -m 0755 "$HERE/baseband/mtk-modemmanager.initd" "$ROOTFS/etc/init.d/mtk-modemmanager"
	fi
}
if [ -e "$ROOTFS$PREFIX" ]; then
	validate_bundle
	check_versions
	install_integration
	select_bundle
	printf 'Selected existing tested baseband bundle %s; no rebuild or hardware startup.\n' "$RELEASE"
	exit 0
fi
mkdir -p "$SOURCE_DIR/owner" "$SOURCE_DIR/mm"
git -C "$WORK/owner" archive HEAD | tar -x -C "$SOURCE_DIR/owner"
git -C "$WORK/mm" archive HEAD | tar -x -C "$SOURCE_DIR/mm"
# /run is private in the build chroot, so retain and temporarily replace DNS.
if [ -e "$ROOTFS/etc/resolv.conf" ] || [ -L "$ROOTFS/etc/resolv.conf" ]; then
	cp -a "$ROOTFS/etc/resolv.conf" "$WORK/resolv.conf"
	DNS_PRESENT=1
fi
DNS_CHANGED=1
rm -f -- "$ROOTFS/etc/resolv.conf"
install -m 0644 /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
distro_install_packages "$ROOTFS" "$BASEBAND_BUILD_PACKAGES"
systemd=true
[ "$INIT_SYSTEM" != openrc ] || systemd=false
distro_chroot "$ROOTFS" meson setup "$TARGET_SOURCE/owner-build" "$TARGET_SOURCE/owner" \
	--prefix="$PREFIX/owner" --libexecdir=libexec
distro_chroot "$ROOTFS" meson compile -C "$TARGET_SOURCE/owner-build" -j "$JOBS"
distro_chroot "$ROOTFS" meson test -C "$TARGET_SOURCE/owner-build" --print-errorlogs
distro_chroot "$ROOTFS" meson setup "$TARGET_SOURCE/mm-build" "$TARGET_SOURCE/mm" \
	--prefix="$PREFIX/mm" --libdir=lib --sysconfdir=etc --datadir=share \
	-Dudevdir="$PREFIX/mm/lib/udev" -Ddbus_policy_dir="$PREFIX/mm/etc/dbus-1/system.d" \
	-Dsystemdsystemunitdir=no -Dsystemd_journal="$systemd" -Dsystemd_suspend_resume="$systemd" \
	-Dauto_features=disabled -Dplugin_mtk_soc=enabled -Dplugin_generic=enabled \
	-Dqmi=false -Dqrtr=false -Dmbim=false -Dintrospection=false -Dvapi=false \
	-Dman=false -Dgtk_doc=false -Dbash_completion=false -Dexamples=false
distro_chroot "$ROOTFS" meson compile -C "$TARGET_SOURCE/mm-build" -j "$JOBS"
distro_chroot "$ROOTFS" meson test -C "$TARGET_SOURCE/mm-build" --print-errorlogs
mkdir -p "$SOURCE_DIR/stage"
distro_chroot "$ROOTFS" env DESTDIR="$TARGET_SOURCE/stage" meson install -C "$TARGET_SOURCE/owner-build"
distro_chroot "$ROOTFS" env DESTDIR="$TARGET_SOURCE/stage" meson install -C "$TARGET_SOURCE/mm-build"
# Reject unexpected system-wide installs before promoting a release.
python3 - "$SOURCE_DIR/stage" "$PREFIX" <<'PY'
from pathlib import Path
import sys
stage = Path(sys.argv[1])
prefix = stage / sys.argv[2].lstrip("/")
for item in stage.rglob("*"):
    if not item.is_dir() and prefix not in item.parents:
        raise SystemExit(f"upstream install escaped private prefix: {item.relative_to(stage)}")
PY
mkdir -p "$ROOTFS/usr/lib/mtk-ccci/releases"
mv "$SOURCE_DIR/stage$PREFIX" "$ROOTFS$PREFIX"
RELEASE_CREATED=1
install_integration
python3 - "$ROOTFS$PREFIX/manifest.json" "$OWNER_COMMIT" "$MM_COMMIT" "$DISTRO" <<'PY'
import json
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(json.dumps({
    "schema": 1, "device": "qqcandy", "distro": sys.argv[4],
    "owner_commit": sys.argv[2], "mm_commit": sys.argv[3],
    "autostart": False, "hardware_validated": False,
}, indent=2) + "\n")
PY
# Resolve libraries and execute version-only entrypoints, never modem control.
check_versions
validate_bundle
select_bundle
printf 'Installed tested baseband bundle %s; hardware startup remains gated.\n' "$RELEASE"
