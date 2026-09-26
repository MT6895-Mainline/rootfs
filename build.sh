#!/usr/bin/env bash
#
# MT6895-Mainline rootfs builder (rootfs branch)
#
# Builds a flashable rootfs image for an MT6895 device:
#   - kernel modules built from the matching linux branch, so vermagic matches
#   - userspace bootstrapped with mmdebstrap (arm64, foreign arch via qemu)
#   - per-device + common overlay applied
#   - optional bring-your-own firmware blobs
#   - outputs a sparse ext4 image (+ option to split for the 2GB release limit)
#
# Output naming follows the sibling xaga build project:
#   rootfs-sparse-<YYYYmmdd-HHMMSS>.img[.gz[.part-NN]]  and SHA256SUMS
#
# Usage:
#   sudo ./build.sh --device pearl --kernel-repo ./linux
#   sudo ./build.sh --device pearl --kernel-repo ./linux --firmware ./firmware \
#                   --hostname pearl --wifi-ssid MyNet --wifi-password secret
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE=""
DISTRO="debian"
SUITE="trixie"
ARCH="arm64"
MIRROR=""
OUT="$HERE/out"
KERNEL_REPO="${KERNEL_REPO:-}"
KERNEL_REF=""
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
ROOT_PASSWORD="root"
WIFI_SSID=""
WIFI_PASSWORD=""
# Kernel make arguments, e.g. "LLVM=1" for clang builds (profile sets it).
KERNEL_MAKE_ARGS="${KERNEL_MAKE_ARGS:-}"

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n=== %s ===\n' "$*"; }

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
	exit 0
}

while [ $# -gt 0 ]; do
	case "$1" in
		--device) DEVICE="${2:?}"; shift 2 ;;
		--distro) DISTRO="${2:?}"; shift 2 ;;
		--suite) SUITE="${2:?}"; shift 2 ;;
		--mirror) MIRROR="${2:?}"; shift 2 ;;
		--out) OUT="${2:?}"; shift 2 ;;
		--ts) TS="${2:?}"; shift 2 ;;
		--kernel-repo) KERNEL_REPO="${2:?}"; shift 2 ;;
		--kernel-ref) KERNEL_REF="${2:?}"; shift 2 ;;
		--kernel-make-args) KERNEL_MAKE_ARGS="${2:?}"; shift 2 ;;
		--firmware) FIRMWARE_DIR="${2:?}"; shift 2 ;;
		--jobs) JOBS="${2:?}"; shift 2 ;;
		--img-size) IMG_SIZE="${2:?}"; shift 2 ;;
		--hostname) HOSTNAME_OVERRIDE="${2:?}"; shift 2 ;;
		--root-password) ROOT_PASSWORD="${2:?}"; shift 2 ;;
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

[ -n "$DEVICE" ] || die "--device is required (see devices/*.conf)"
[ -f "$HERE/devices/$DEVICE.conf" ] || die "no profile for device '$DEVICE'"
[ -f "$HERE/distros/$DISTRO.sh" ] || die "no distro backend 'distros/$DISTRO.sh'"

# shellcheck source=/dev/null
. "$HERE/devices/$DEVICE.conf"

: "${KERNEL_BRANCH:?profile must set KERNEL_BRANCH}"
: "${KERNEL_CONFIGS:?profile must set KERNEL_CONFIGS}"
: "${ROOTFS_LABEL:?profile must set ROOTFS_LABEL}"
KERNEL_REF="${KERNEL_REF:-$KERNEL_BRANCH}"
DISTRO_NAME="$(basename "$DISTRO")"
HOSTNAME_OVERRIDE="${HOSTNAME_OVERRIDE:-$DEVICE}"

for tool in mmdebstrap mkfs.ext4 zstd du findmnt depmod; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done
[ "$(id -u)" = "0" ] || die "must run as root"
[ -n "$KERNEL_REPO" ] || die "--kernel-repo (or \$KERNEL_REPO) is required"
[ -d "$KERNEL_REPO/.git" ] || die "kernel repo '$KERNEL_REPO' is not a git checkout"

WORK="$OUT/.work-$DEVICE-$DISTRO_NAME"
ROOTFS="$WORK/rootfs"
KBOUT="$WORK/kernel"
# the device name is part of the image name: several devices are built in one
# run and their artifacts are collected into a single release
STUB="rootfs-$DEVICE$NAME_SUFFIX-$TS"
BASE="$STUB.img"
IMGF="$OUT/$BASE"
rm -rf "$WORK"
mkdir -p "$ROOTFS" "$KBOUT" "$OUT"

# ---------------------------------------------------------------- kernel modules
log "0. kernel '$KERNEL_REF' from $KERNEL_REPO"
KVER="$(git -C "$KERNEL_REPO" show "$KERNEL_REF:Makefile" 2>/dev/null \
	| awk -F' = ' '/^(VERSION|PATCHLEVEL|SUBLEVEL) =/{printf "%s%s", sep, $2; sep="."}')"
[ -n "$KVER" ] || die "cannot determine kernel version for $KERNEL_REF"
echo "kernel version: $KVER"

git -C "$KERNEL_REPO" archive --format=tar "$KERNEL_REF" | tar -x -C "$KBOUT"
cd "$KBOUT"

log "1. kernel config (defconfig + ${KERNEL_CONFIGS})"
export ARCH
echo "kernel make args: ${KERNEL_MAKE_ARGS:-<none>}"
for cfg in $KERNEL_CONFIGS; do
	[ -f "arch/arm64/configs/$cfg" ] || die "missing arch/arm64/configs/$cfg"
done
# shellcheck disable=SC2086
make -s $KERNEL_MAKE_ARGS defconfig
for cfg in $KERNEL_CONFIGS; do
	scripts/kconfig/merge_config.sh -m -O . .config "arch/arm64/configs/$cfg" >/dev/null
done
# shellcheck disable=SC2086
make -s $KERNEL_MAKE_ARGS olddefconfig
grep -E '^CONFIG_(LOCALVERSION|MODVERSIONS|MODULE_SIG|BLK_DEV_INITRD|INITRAMFS_FORCE)=' .config || true

log "2. build modules"
# shellcheck disable=SC2086
make -j"$JOBS" $KERNEL_MAKE_ARGS modules

# ---------------------------------------------------------------- userspace
log "3. bootstrap $DISTRO_NAME/$SUITE ($ARCH)"
# shellcheck source=/dev/null
. "$HERE/distros/$DISTRO_NAME.sh"
distro_bootstrap "$ROOTFS" "$SUITE" "$ARCH" "$MIRROR" "$JOBS"
distro_configure "$ROOTFS" "$SUITE"

log "4. install kernel modules"
# shellcheck disable=SC2086
make $KERNEL_MAKE_ARGS INSTALL_MOD_PATH="$ROOTFS" INSTALL_MOD_STRIP=1 modules_install
rm -f "$ROOTFS/lib/modules/$KVER/build" "$ROOTFS/lib/modules/$KVER/source"
depmod -b "$ROOTFS" "$KVER" 2>/dev/null || echo "warning: depmod failed (will run on first boot)"

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
if [ -n "$DEFAULT_USER" ] && [ -d "$ROOTFS/home/$DEFAULT_USER" ]; then
	echo "$DEFAULT_USER ALL=(ALL:ALL) NOPASSWD:ALL" > "$ROOTFS/etc/sudoers.d/010-$DEFAULT_USER"
	chmod 0440 "$ROOTFS/etc/sudoers.d/010-$DEFAULT_USER"
fi
if [ -n "$ROOT_PASSWORD" ]; then
	chroot "$ROOTFS" /bin/sh -c "echo 'root:$ROOT_PASSWORD' | chpasswd" || \
		echo "warning: could not set the root password"
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
rm -rf "$ROOTFS/var/cache/apt"/* "$ROOTFS/var/lib/apt/lists"/* 2>/dev/null || true
rm -rf "$ROOTFS/tmp"/* 2>/dev/null || true
install -d -m 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"

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

( cd "$OUT" && sha256sum -- * > SHA256SUMS 2>/dev/null ) || true
[ -f "$OUT/SHA256SUMS" ] && cat "$OUT/SHA256SUMS"

if [ "$STAGE_ROOTFS" = "1" ]; then
	echo "rootfs tree kept at: $ROOTFS"
elif [ "$KEEP_WORK" != "1" ]; then
	rm -rf "$WORK"
fi

log "done"
cat <<EOF
device    : $DEVICE  ($PLATFORM_NAME)
kernel    : $KERNEL_REF = $KVER
rootfs    : $DISTRO_NAME/$SUITE $ARCH
userdata  : $USERDATA_PART (${NVDATA_PART:+nvdata $NVDATA_PART})
timestamp : $TS

flash:
  fastboot flash userdata $(basename "$IMGF")${IMGF:+}
  fastboot reboot
first boot resizes the filesystem to fill the partition.
EOF
