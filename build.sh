#!/usr/bin/env bash
#
# MT6895-Mainline userspace rootfs builder
#
# Builds a userspace rootfs image for an MT6895 device:
#   - optional import of externally built matching ARM64 kernel modules
#   - Debian/Mobian, Arch Linux ARM or Nura userspace (ARM64 via QEMU)
#   - per-device + common overlay applied
#   - optional bring-your-own firmware blobs
#   - outputs a sparse ext4 image (+ option to split for the 2GB release limit)
#
# Output naming follows the sibling xaga build project:
#   rootfs-<device>-<distro>-<timestamp>-sparse.img[.gz] and SHA256SUMS
#
# Usage:
#   sudo ./build.sh --device pearl
#   sudo ./build.sh --device pearl --firmware ./firmware \
#                   --hostname pearl --wifi-ssid MyNet --wifi-password secret
#   sudo ./build.sh --device qqcandy --distro nura
#   sudo ./build.sh --device qqcandy --distro nura --baseband-support /private/support
#   sudo ./build.sh --device qqcandy --distro arch --no-image --tar
#   sudo ./build.sh --device qqcandy --modules /path/lib/modules/6.18.0+ \
#                   --kernel-release 6.18.0+
# No kernel, DTB, initramfs or boot image is built. Boot is supplied separately.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE=""
DISTRO="debian"
SUITE=""
ARCH="arm64"
MIRROR=""
OUT="$HERE/out"
MODULES_DIR=""
KVER=none
FIRMWARE_DIR=""
JOBS="$(nproc)"
TS="$(date -u +%Y%m%d-%H%M%S)"
IMG_SIZE=""
MAKE_IMAGE=1
MAKE_TAR=0
SPLIT_ABOVE=2000000000
STAGE_ROOTFS=0
KEEP_WORK="${KEEP_WORK:-0}"
NAME_SUFFIX="${NAME_SUFFIX:-}"
HOSTNAME_OVERRIDE=""
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
USER_PASSWORD="${USER_PASSWORD:-1234}"
UI=phosh
VAAPI=auto
BASEBAND=auto
BASEBAND_OWNER_REF=latest
BASEBAND_MM_REF=latest
BASEBAND_SUPPORT=""
PHOSH_CUTOUT=auto
WIFI_SSID=""
WIFI_PASSWORD=""

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n=== %s ===\n' "$*"; }

# CI logs are not reachable without a token, but workflow annotations are, so
# make the failing line announce itself instead of leaving only an exit code.
trap 'rc=$?; if [ "$rc" != "0" ]; then
	printf "::error title=build.sh failed::exit %s at line %s: %s\n" \
		"$rc" "$LINENO" "$BASH_COMMAND" >&2
fi' ERR

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
	exit 0
}

while [ $# -gt 0 ]; do
	case "$1" in
		--device) DEVICE="${2:?}"; shift 2 ;;
		--distro) DISTRO="${2:?}"; shift 2 ;;
		--suite) SUITE="${2:?}"; shift 2 ;;
		--ui) UI="${2:?}"; shift 2 ;;
		--rootfs-only) MAKE_IMAGE=0; MAKE_TAR=1; shift ;;
		--vaapi) VAAPI="${2:?}"; shift 2 ;;
		--baseband) BASEBAND="${2:?}"; shift 2 ;;
		--baseband-owner-ref) BASEBAND_OWNER_REF="${2:?}"; shift 2 ;;
		--baseband-mm-ref) BASEBAND_MM_REF="${2:?}"; shift 2 ;;
		--baseband-support) BASEBAND_SUPPORT="${2:?}"; shift 2 ;;
		--phosh-cutout) PHOSH_CUTOUT="${2:?}"; shift 2 ;;
		--mirror) MIRROR="${2:?}"; shift 2 ;;
		--out) OUT="${2:?}"; shift 2 ;;
		--ts) TS="${2:?}"; shift 2 ;;
		--modules) MODULES_DIR="${2:?}"; shift 2 ;;
		--kernel-release) KVER="${2:?}"; shift 2 ;;
		--kernel-*|--initramfs-*) die "$1 was removed: build boot separately; import --modules with --kernel-release" ;;
		--firmware) FIRMWARE_DIR="${2:?}"; shift 2 ;;
		--jobs) JOBS="${2:?}"; shift 2 ;;
		--img-size) IMG_SIZE="${2:?}"; shift 2 ;;
		--hostname) HOSTNAME_OVERRIDE="${2:?}"; shift 2 ;;
		--root-password) ROOT_PASSWORD="${2:?}"; shift 2 ;;
		--user-password) USER_PASSWORD="${2:?}"; shift 2 ;;
		--wifi-ssid) WIFI_SSID="${2:?}"; shift 2 ;;
		--wifi-password) WIFI_PASSWORD="${2:?}"; shift 2 ;;
		--name-suffix) NAME_SUFFIX="${2:?}"; shift 2 ;;
		--no-image) MAKE_IMAGE=0; shift ;;
		--tar) MAKE_TAR=1; shift ;;
		--stage-rootfs) STAGE_ROOTFS="${2:?}"; shift 2 ;;
		--keep-work) KEEP_WORK=1; shift ;;
		-h|--help) usage ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ "$DISTRO" != pmos ] || DISTRO=nura

for value in "$ROOT_PASSWORD" "$USER_PASSWORD" "$WIFI_SSID" "$WIFI_PASSWORD"; do
	[[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "credentials must be single-line"
done

[ -n "$DEVICE" ] || die "--device is required (see devices/*.conf)"
[[ "$DEVICE" =~ ^[a-z0-9-]+$ && "$DISTRO" =~ ^[a-z0-9-]+$ ]] || die "invalid profile name"
case "$UI" in console|phosh) ;; *) die "--ui must be console or phosh" ;; esac
case "$VAAPI" in auto|on|off) ;; *) die "--vaapi must be auto, on or off" ;; esac
case "$BASEBAND" in auto|on|off) ;; *) die "--baseband must be auto, on or off" ;; esac
case "$PHOSH_CUTOUT" in auto|on|off) ;; *) die '--phosh-cutout must be auto, on or off' ;; esac
if [ "$PHOSH_CUTOUT" = on ]; then
	if [ "$DEVICE" != qqcandy ] || [ "$DISTRO" != nura ] || [ "$UI" != phosh ]; then
		die 'native cutout support is currently reviewed only for qqcandy/Nura/Phosh'
	fi
fi
for ref in "$BASEBAND_OWNER_REF" "$BASEBAND_MM_REF"; do
	[[ "$ref" = latest || "$ref" =~ ^[0-9a-f]{40}$ ]] || die 'baseband refs must be latest or full commit IDs'
done
[[ "$TS" =~ ^[0-9-]+$ && "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "invalid timestamp/jobs"
[ -f "$HERE/devices/$DEVICE.conf" ] || die "no profile for device '$DEVICE'"
[ -f "$HERE/distros/$DISTRO.sh" ] || die "no distro backend 'distros/$DISTRO.sh'"

# shellcheck source=/dev/null
. "$HERE/devices/$DEVICE.conf"
[ "$BASEBAND" != on ] || [ -n "${BASEBAND_OWNER_REPO:-}" ] || die 'profile has no baseband support'
BASEBAND_INSTALLED=0
PHOSH_CUTOUT_INSTALLED=0

: "${ROOTFS_LABEL:?profile must set ROOTFS_LABEL}"
DISTRO_NAME="$(basename "$DISTRO")"
HOSTNAME_OVERRIDE="${HOSTNAME_OVERRIDE:-$DEVICE}"

[ "$(id -u)" = "0" ] || die "must run as root"
if [ -n "$BASEBAND_SUPPORT" ]; then
	if [ "$DEVICE" != qqcandy ] || [ "$BASEBAND" = off ]; then
		die '--baseband-support requires qqcandy baseband installation'
	fi
	BASEBAND_SUPPORT="$(realpath -e "$BASEBAND_SUPPORT")"
	python3 "$HERE/tools/provision-baseband.py" --source "$BASEBAND_SUPPORT" --check-only
fi
if [ -n "$MODULES_DIR" ]; then
	[ "$KVER" != none ] || die '--modules requires --kernel-release'
	MODULES_DIR="$(realpath -e "$MODULES_DIR")"
	python3 "$HERE/tools/import-modules.py" --source "$MODULES_DIR" --release "$KVER" --check-only
else
	[ "$KVER" = none ] || die '--kernel-release requires --modules'
fi

# Distro backends declare their host tools and own the bootstrap/configure
# contract. The userspace image path is shared across distros.
. "$HERE/distros/$DISTRO.sh"
SUITE="${SUITE:-$DISTRO_DEFAULT_SUITE}"
[[ "$SUITE" =~ ^[a-z0-9.-]+$ && "$HOSTNAME_OVERRIDE" =~ ^[a-zA-Z0-9.-]+$ ]] ||
	die "invalid suite or hostname"
[[ "$DEFAULT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid default user"
: "${DISTRO_HOST_TOOLS:?distro backend must set DISTRO_HOST_TOOLS}"
for tool in mkfs.ext4 zstd du findmnt git $DISTRO_HOST_TOOLS; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done
[ -z "$FIRMWARE_DIR" ] || FIRMWARE_DIR="$(realpath -e "$FIRMWARE_DIR")"

mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
WORK="$(mktemp -d "$OUT/.work-$DEVICE-$DISTRO_NAME.XXXXXX")"
ROOTFS="$WORK/rootfs"
# the device name is part of the image name: several devices are built in one
# run and their artifacts are collected into a single release
STUB="rootfs-$DEVICE-$DISTRO_NAME$NAME_SUFFIX-$TS"
BASE="$STUB.img"
IMGF="$OUT/$BASE"
mkdir -p "$ROOTFS" "$OUT"
# The script runs as root, but later CI steps (build info) write into --out as
# the invoking user, so hand the directory over when sudo tells us who that is.
if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
	chown "$SUDO_UID:$SUDO_GID" "$OUT" 2>/dev/null || true
fi

# ---------------------------------------------------------------- userspace
log "3. bootstrap $DISTRO_NAME/$SUITE ($ARCH)"
distro_bootstrap "$ROOTFS" "$SUITE" "$ARCH" "$MIRROR" "$JOBS"
distro_configure "$ROOTFS" "$SUITE"

if [ -n "$MODULES_DIR" ]; then
	log '4. import externally built kernel modules (no compilation)'
	python3 "$HERE/tools/import-modules.py" --source "$MODULES_DIR" --release "$KVER" --root "$ROOTFS"
fi

# ---------------------------------------------------------------- optional userspace components
install_vaapi_driver() {
	local repo="${VAAPI_REPO:-}" commit="${VAAPI_COMMIT:-}"
	local src="$WORK/vaapi-mtk-vcp"
	[ "$VAAPI" != off ] || return 0
	[ "$VAAPI" != on ] || [ -n "$repo" ] || die "profile has no VAAPI_REPO"
	[ -n "$repo" ] || return 0
	[ -n "$commit" ] || die "VAAPI_COMMIT is required when VAAPI_REPO is set"
	distro_install_packages "$ROOTFS" "${VAAPI_BUILD_PACKAGES:-}"
	git clone --filter=blob:none --no-checkout "$repo" "$src"
	git -C "$src" checkout --detach "$commit"
	[ "$(git -C "$src" rev-parse HEAD)" = "$commit" ] ||
		die "VA-API source did not resolve to pinned commit"
	install -d "$ROOTFS/usr/src/vaapi-mtk-vcp"
	git -C "$src" archive HEAD | tar -x -C "$ROOTFS/usr/src/vaapi-mtk-vcp"
	distro_chroot "$ROOTFS" /bin/sh -c \
		"cd /usr/src/vaapi-mtk-vcp && make -j${JOBS}"
	local driverdir
	driverdir="$(distro_chroot "$ROOTFS" pkg-config --variable=libdir libva)/dri"
	[[ "$driverdir" = /usr/lib* && "$driverdir" != *..* ]] ||
		die "invalid libva driver directory: $driverdir"
	install -d -m 0755 "$ROOTFS$driverdir"
	install -m 0755 "$ROOTFS/usr/src/vaapi-mtk-vcp/mtk_vcp_drv_video.so" \
		"$ROOTFS$driverdir/mtk_vcp_drv_video.so"
	rm -rf "$ROOTFS/usr/src/vaapi-mtk-vcp"
	install -d "$ROOTFS/usr/share/mt6895-build"
	printf '%s\n%s\n' "$repo" "$commit" > "$ROOTFS/usr/share/mt6895-build/vaapi-source"
}

install_vaapi_driver

if [ "$BASEBAND" != off ]; then
	if [ -n "${BASEBAND_OWNER_REPO:-}" ]; then
		log '4b. install tested baseband userspace (no automatic hardware startup)'
		bash "$HERE/tools/install-baseband.sh" --root "$ROOTFS" --device "$DEVICE" --distro "$DISTRO" \
			--owner-ref "$BASEBAND_OWNER_REF" --mm-ref "$BASEBAND_MM_REF" --jobs "$JOBS"
		BASEBAND_INSTALLED=1
	fi
fi

if [ -n "${QUIRKS_REPO:-}" ]; then
	git clone --filter=blob:none "$QUIRKS_REPO" "$WORK/quirks"
	git -C "$WORK/quirks" checkout --detach "${QUIRKS_COMMIT:?profile must pin quirks}"
	make -C "$WORK/quirks" DEVICE="$DEVICE" DESTDIR="$ROOTFS" install
fi

# ---------------------------------------------------------------- overlay
log "5. overlay (common + $DEVICE)"
apply_overlay() {
	local src="$1" dst="$2" f rel mode
	[ -d "$src" ] || return 0
	while IFS= read -r -d '' f; do
		rel="${f#"$src"/}"
		mode="$(stat -c '%a' "$f")"
		install -D -m "$mode" "$f" "$dst/$rel"
	done < <(find "$src" -type f -print0)
}
apply_overlay "$HERE/overlay/common" "$ROOTFS"
apply_overlay "$HERE/overlay/$DEVICE" "$ROOTFS"
apply_overlay "$HERE/ui/$UI/$DEVICE" "$ROOTFS"

log "6. identity, users, fstab"
echo "$HOSTNAME_OVERRIDE" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$HOSTNAME_OVERRIDE

::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF
: > "$ROOTFS/etc/machine-id"
cat > "$ROOTFS/etc/fstab" <<EOF
# MT6895-Mainline: the root filesystem is an ext4 image flashed into the
# userdata partition (partlabel "userdata") and labelled $ROOTFS_LABEL.
LABEL=$ROOTFS_LABEL	/	ext4	defaults,noatime,errors=remount-ro	0 1
EOF

DEFAULT_USER="${DEFAULT_USER:-mobian}"
if [ -n "$ROOT_PASSWORD" ]; then
	printf 'root:%s\n' "$ROOT_PASSWORD" | distro_chroot "$ROOTFS" chpasswd
fi
if [ -n "$USER_PASSWORD" ]; then
	printf '%s:%s\n' "$DEFAULT_USER" "$USER_PASSWORD" | distro_chroot "$ROOTFS" chpasswd
fi

if [ -n "$WIFI_SSID" ]; then
	log "6b. preseeded wifi"
	install -d -m 0700 "$ROOTFS/etc/NetworkManager/system-connections"
	cat > "$ROOTFS/etc/NetworkManager/system-connections/mt6895.nmconnection" <<EOF
[connection]
id=mt6895-wifi
type=wifi
autoconnect=true

[wifi]
ssid=$WIFI_SSID
mode=infrastructure

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PASSWORD

[ipv4]
method=auto

[ipv6]
method=auto
EOF
	chmod 0600 "$ROOTFS/etc/NetworkManager/system-connections/mt6895.nmconnection"
fi

# ---------------------------------------------------------------- firmware
log "7. firmware"
if [ -n "$FIRMWARE_DIR" ]; then
	[ -d "$FIRMWARE_DIR" ] || die "--firmware '$FIRMWARE_DIR' is not a directory"
	install -d "$ROOTFS/lib/firmware"
	cp -a "$FIRMWARE_DIR/." "$ROOTFS/lib/firmware/"
	echo "installed vendor blobs from $FIRMWARE_DIR"
else
	echo "no --firmware: image ships without proprietary blobs."
	echo "install them later with tools/install-firmware.sh on the device."
fi

# ---------------------------------------------------------------- finalise
log "8. finalise"
if [ "$PHOSH_CUTOUT" != off ] && [ "$DEVICE" = qqcandy ] && [ "$DISTRO" = nura ] && [ "$UI" = phosh ]; then
	log '7b. build device-tested native Phosh/Phrog cutout layout'
	bash "$HERE/tools/install-phosh-cutout.sh" --root "$ROOTFS" --device "$DEVICE" --distro "$DISTRO" --jobs "$JOBS"
	PHOSH_CUTOUT_INSTALLED=1
fi
distro_finalize "$ROOTFS"
if [ -n "$BASEBAND_SUPPORT" ]; then
	log '8a. provision private baseband support and guarded automatic startup'
	python3 "$HERE/tools/provision-baseband.py" --root "$ROOTFS" --distro "$DISTRO" --source "$BASEBAND_SUPPORT"
fi
rm -rf "$ROOTFS/var/cache/apt"/* "$ROOTFS/var/lib/apt/lists"/* 2>/dev/null || true
rm -rf "$ROOTFS/tmp"/* 2>/dev/null || true
install -d -m 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"

log "8b. validate image contracts"
checks=("$ROOTFS" --device "$DEVICE" --user "$DEFAULT_USER" --init "$INIT_SYSTEM"
	--ui "$UI" --kernel "$KVER" --ssh-unit "${SSH_UNIT:-ssh.service}"
	--phosh-unit "${PHOSH_UNIT:-greetd.service}")
if [ "$UI" = phosh ]; then
	distro_chroot "$ROOTFS" glib-compile-schemas --strict /usr/share/glib-2.0/schemas
	if [ "$DEVICE" = qqcandy ]; then
		filter="$(distro_chroot "$ROOTFS" env GSETTINGS_BACKEND=memory \
			gsettings get sm.puri.phosh app-filter-mode)"
		[ "$filter" = '@as []' ] || die 'qqcandy Phosh must show all installed applications'
	fi
	distro_chroot "$ROOTFS" gsettings list-schemas > "$WORK/glib-schemas.txt"
	checks+=(--gsettings-schemas "$WORK/glib-schemas.txt")
fi
[ -z "$ROOT_PASSWORD" ] || checks+=(--allow-root-password)
[ "$BASEBAND_INSTALLED" = 0 ] || checks+=(--baseband)
[ "$PHOSH_CUTOUT_INSTALLED" = 0 ] || checks+=(--phosh-cutout)
if [ "$VAAPI" != off ] && [ -n "${VAAPI_REPO:-}" ]; then
	checks+=(--vaapi)
fi
python3 "$HERE/tools/validate-rootfs.py" "${checks[@]}"

if [ "$MAKE_TAR" = "1" ]; then
	log "9. tar.zst"
	( cd "$ROOTFS" && tar --numeric-owner --xattrs -I 'zstd -19 -T0' -cpf "$OUT/$STUB.tar.zst" . )
fi

if [ "$MAKE_IMAGE" = "1" ]; then
	log "9. ext4 image"
	USED_MB="$(( $(du -sm "$ROOTFS" | cut -f1) + 320 ))"
	[ -n "$IMG_SIZE" ] || IMG_SIZE="$(( (USED_MB + 1023) / 1024 ))G"
	truncate -s "$IMG_SIZE" "$IMGF"
	mkfs.ext4 -q -F -L "$ROOTFS_LABEL" -E root_owner=0:0 -d "$ROOTFS" "$IMGF"
	echo "ext4: $IMGF ($IMG_SIZE, label $ROOTFS_LABEL)"

	if command -v img2simg >/dev/null 2>&1; then
		log "10. sparse image + gzip"
		img2simg "$IMGF" "$OUT/$STUB-sparse.img"
		rm -f "$IMGF"
		IMGF="$OUT/$STUB-sparse.img"
		pigz -9 -k -p"$JOBS" "$IMGF" 2>/dev/null || gzip -9 -k "$IMGF"
		GZ="$IMGF.gz"
		BYTES="$(stat -c%s "$GZ")"
		if [ "$BYTES" -gt "$SPLIT_ABOVE" ]; then
			split -b 1900M -d -a 2 "$GZ" "$GZ.part-"
			rm -f "$GZ"
			echo "image is $(( BYTES / 1048576 )) MiB: split for the 2GB per-file release limit"
			ls -l "$GZ".part-*
			echo "rejoin with: cat $(basename "$GZ").part-* > $(basename "$GZ")"
		else
			echo "gzip: $GZ ($(( BYTES / 1048576 )) MiB)"
		fi
	else
		echo "warning: img2simg not found (install android-sdk-libsparse-utils);" \
		     "shipping the plain ext4 image"
		gzip -9 -k "$IMGF" || true
	fi
fi

cat > "$OUT/USERSPACE-INFO-$DEVICE$NAME_SUFFIX-$DISTRO_NAME.txt" <<EOF
device:          $DEVICE
distribution:    $DISTRO_NAME/$SUITE
boot artifacts:  external (not built by this repository)
module release:  $KVER
module manifest: /usr/share/mt6895-build/kernel-modules.json (when imported)

Imported modules require the exact matching external boot/configuration.
Release/vermagic checks are not hardware or symbol-version validation.
EOF
cat "$OUT/USERSPACE-INFO-$DEVICE$NAME_SUFFIX-$DISTRO_NAME.txt"
if [ -n "$MODULES_DIR" ]; then
	cp "$ROOTFS/usr/share/mt6895-build/kernel-modules.json" "$OUT/MODULES-$DEVICE$NAME_SUFFIX-$DISTRO_NAME.json"
fi

( cd "$OUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\0' |
	sort -z | xargs -0 -r sha256sum > SHA256SUMS )
[ -f "$OUT/SHA256SUMS" ] && cat "$OUT/SHA256SUMS"

if [ "$STAGE_ROOTFS" = "1" ]; then
	echo "rootfs tree kept at: $ROOTFS"
elif [ "$KEEP_WORK" != "1" ]; then
	rm -rf "$WORK"
fi

log "done"
cat <<EOF
device    : $DEVICE  ($PLATFORM_NAME)
modules   : $KVER (optional external import)
rootfs    : $DISTRO_NAME/$SUITE $ARCH
userdata  : $USERDATA_PART (${NVDATA_PART:+nvdata $NVDATA_PART})
timestamp : $TS

Deployment erases userdata. Use the device-specific boot/recovery procedure.
This builder never flashes partitions or builds boot. Supply a validated external boot.
EOF
