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
#   sudo ./build.sh --device pearl --kernel-repo ./linux \
#                   --kernel-config /path/to/the/kernel/.config
#   sudo ./build.sh --device pearl --kernel-repo ./linux --kernel-localversion "+"
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE=""
DISTRO="debian"
SUITE=""
ARCH="arm64"
MIRROR=""
OUT="$HERE/out"
KERNEL_REPO="${KERNEL_REPO:-}"
KERNEL_REF=""
# Optional full .config.  Use this when the boot image you flash was built from
# a config that is not exactly `defconfig + <device>.config`: the modules have to
# agree with that config or they will refuse to load.
KERNEL_CONFIG_FILE="${KERNEL_CONFIG_FILE:-}"
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
ROOTFS_ONLY=0
VAAPI=auto
WIFI_SSID=""
WIFI_PASSWORD=""
# Kernel make arguments, e.g. "LLVM=1" for clang builds (profile sets it).
KERNEL_MAKE_ARGS="${KERNEL_MAKE_ARGS:-}"
# Local version suffix the flashed kernel carries (profile sets it, e.g. "+").
KERNEL_LOCALVERSION_ARG=""
KERNEL_LOCALVERSION_SET=0

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n=== %s ===\n' "$*"; }
kernel_git() { git -c safe.directory="$KERNEL_REPO" -C "$KERNEL_REPO" "$@"; }

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
		--rootfs-only) ROOTFS_ONLY=1; MAKE_IMAGE=0; shift ;;
		--vaapi) VAAPI="${2:?}"; shift 2 ;;
		--mirror) MIRROR="${2:?}"; shift 2 ;;
		--out) OUT="${2:?}"; shift 2 ;;
		--ts) TS="${2:?}"; shift 2 ;;
		--kernel-repo) KERNEL_REPO="${2:?}"; shift 2 ;;
		--kernel-ref) KERNEL_REF="${2:?}"; shift 2 ;;
		--kernel-config) KERNEL_CONFIG_FILE="${2:?}"; shift 2 ;;
		--kernel-localversion) KERNEL_LOCALVERSION_ARG="${2:-}"; KERNEL_LOCALVERSION_SET=1; shift 2 ;;
		--kernel-make-args) KERNEL_MAKE_ARGS="${2:?}"; shift 2 ;;
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

for value in "$ROOT_PASSWORD" "$USER_PASSWORD" "$WIFI_SSID" "$WIFI_PASSWORD"; do
	[[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "credentials must be single-line"
done

[ -n "$DEVICE" ] || die "--device is required (see devices/*.conf)"
[[ "$DEVICE" =~ ^[a-z0-9-]+$ && "$DISTRO" =~ ^[a-z0-9-]+$ ]] || die "invalid profile name"
case "$UI" in console|phosh) ;; *) die "--ui must be console or phosh" ;; esac
case "$VAAPI" in auto|on|off) ;; *) die "--vaapi must be auto, on or off" ;; esac
[[ "$TS" =~ ^[0-9-]+$ && "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "invalid timestamp/jobs"
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
# A profile may pin the exact config the device's boot image was built from
# (KERNEL_FULL_CONFIG="configs/<file>.config").  --kernel-config still wins.
if [ -z "$KERNEL_CONFIG_FILE" ] && [ -n "${KERNEL_FULL_CONFIG:-}" ]; then
	case "$KERNEL_FULL_CONFIG" in
		/*) KERNEL_CONFIG_FILE="$KERNEL_FULL_CONFIG" ;;
		*)  KERNEL_CONFIG_FILE="$HERE/$KERNEL_FULL_CONFIG" ;;
	esac
	echo "profile pins the kernel config: $KERNEL_CONFIG_FILE"
fi
# The profile sets the suffix the flashed kernel reports in `uname -r`;
# --kernel-localversion overrides it (also used to clear it).
KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION_ARG:-${KERNEL_LOCALVERSION:-}}"
[ "$KERNEL_LOCALVERSION_SET" = 0 ] || KERNEL_LOCALVERSION="$KERNEL_LOCALVERSION_ARG"

[ "$(id -u)" = "0" ] || die "must run as root"
if [ "$ROOTFS_ONLY" = 0 ]; then
	[ -n "$KERNEL_REPO" ] || die "--kernel-repo (or \$KERNEL_REPO) is required"
	KERNEL_REPO="$(realpath "$KERNEL_REPO")"
	kernel_git rev-parse --is-inside-work-tree >/dev/null ||
		die "kernel repo '$KERNEL_REPO' is not a git checkout"
	KERNEL_REPO="$(realpath "$KERNEL_REPO")"
fi

# Distro backends declare their host tools and own the bootstrap/configure
# contract. This keeps the kernel/module/image path shared across distros.
. "$HERE/distros/$DISTRO.sh"
SUITE="${SUITE:-$DISTRO_DEFAULT_SUITE}"
[[ "$SUITE" =~ ^[a-z0-9.-]+$ && "$HOSTNAME_OVERRIDE" =~ ^[a-zA-Z0-9.-]+$ ]] ||
	die "invalid suite or hostname"
[[ "$DEFAULT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid default user"
: "${DISTRO_HOST_TOOLS:?distro backend must set DISTRO_HOST_TOOLS}"
for tool in mkfs.ext4 zstd du findmnt depmod git $DISTRO_HOST_TOOLS; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done

mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
WORK="$(mktemp -d "$OUT/.work-$DEVICE-$DISTRO_NAME.XXXXXX")"
ROOTFS="$WORK/rootfs"
KBOUT="$WORK/kernel"
# the device name is part of the image name: several devices are built in one
# run and their artifacts are collected into a single release
STUB="rootfs-$DEVICE-$DISTRO_NAME$NAME_SUFFIX-$TS"
[ "$ROOTFS_ONLY" = 0 ] || STUB="userspace-only-$DEVICE-$DISTRO_NAME-$TS"
BASE="$STUB.img"
IMGF="$OUT/$BASE"
mkdir -p "$ROOTFS" "$KBOUT" "$OUT"
# The script runs as root, but later CI steps (build info) write into --out as
# the invoking user, so hand the directory over when sudo tells us who that is.
if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
	chown "$SUDO_UID:$SUDO_GID" "$OUT" 2>/dev/null || true
fi

# ---------------------------------------------------------------- kernel modules
KVER=none
CONFIG_SOURCE=none
if [ "$ROOTFS_ONLY" = 0 ]; then
log "0. kernel '$KERNEL_REF' from $KERNEL_REPO"
KERNEL_COMMIT="$(kernel_git rev-parse "$KERNEL_REF^{commit}")"
KVER_MAKEFILE="$(kernel_git show "$KERNEL_REF:Makefile" 2>/dev/null \
	| awk -F' = ' '/^(VERSION|PATCHLEVEL|SUBLEVEL) =/{printf "%s%s", sep, $2; sep="."}')"
[ -n "$KVER_MAKEFILE" ] || die "cannot determine kernel version for $KERNEL_REF"
echo "kernel version in the Makefile: $KVER_MAKEFILE"

kernel_git archive --format=tar "$KERNEL_REF" | tar -x -C "$KBOUT"
cd "$KBOUT"

log "1. kernel config"
export ARCH
echo "kernel make args: ${KERNEL_MAKE_ARGS:-<none>}"
# A full config wins: whoever supplies it knows the exact config the boot image
# was built with, which is the only thing that guarantees the modules load.
CONFIG_SOURCE=""
if [ -n "$KERNEL_CONFIG_FILE" ]; then
	[ -f "$KERNEL_CONFIG_FILE" ] || die "--kernel-config '$KERNEL_CONFIG_FILE' is not a file"
	cp "$KERNEL_CONFIG_FILE" .config
	CONFIG_SOURCE="$(cd "$(dirname "$KERNEL_CONFIG_FILE")" && pwd)/$(basename "$KERNEL_CONFIG_FILE")"
	echo "using the supplied .config: $CONFIG_SOURCE"
else
	frags="arch/arm64/configs/defconfig"
	for cfg in $KERNEL_CONFIGS; do
		[ -f "arch/arm64/configs/$cfg" ] || die "missing arch/arm64/configs/$cfg"
		frags="$frags arch/arm64/configs/$cfg"
	done
	# The branches' own defconfig enables MediaTek AFE drivers for other SoCs
	# that do not compile there; the fixups switch them off (they are useless on
	# MT6895).  A pinned full config already has them off and skips this.
	if [ -f "$HERE/configs/mt6895-fixups.config" ]; then
		frags="$frags $HERE/configs/mt6895-fixups.config"
	fi
	CONFIG_SOURCE="defconfig + $KERNEL_CONFIGS + fixups"
	echo "merging: $CONFIG_SOURCE"
	# The device fragments document this exact procedure in their own header:
	#   scripts/kconfig/merge_config.sh arch/arm64/configs/defconfig <device>.config
	# Start from a clean slate so the result does not depend on a stale .config
	# in the checkout.
	rm -f .config
	# shellcheck disable=SC2086
	scripts/kconfig/merge_config.sh -m $frags
fi
# shellcheck disable=SC2086
make -s $KERNEL_MAKE_ARGS olddefconfig
if [ "$KERNEL_LOCALVERSION_SET" = 1 ]; then
	scripts/config --set-str LOCALVERSION "$KERNEL_LOCALVERSION"
	# shellcheck disable=SC2086
	make -s $KERNEL_MAKE_ARGS olddefconfig
fi
if ! grep -q '^CONFIG_EXTRA_FIRMWARE=""' .config && grep -q '^CONFIG_EXTRA_FIRMWARE=' .config; then
	[ -n "$FIRMWARE_DIR" ] || die "kernel embeds firmware; supply --firmware or a source-only --kernel-config"
	scripts/config --set-str EXTRA_FIRMWARE_DIR "$(realpath "$FIRMWARE_DIR")"
	make -s $KERNEL_MAKE_ARGS olddefconfig
fi
grep -E '^CONFIG_(LOCALVERSION|MODVERSIONS|MODULE_SIG|BLK_DEV_INITRD|INITRAMFS_FORCE)=' .config || true

# `uname -r` on a device that was built from a git tree is usually not the bare
# Makefile version (a tree that is not at a tag gets a trailing "+"), and the
# module directory has to match it exactly or nothing loads.  Ask the tree
# itself, and force CONFIG_LOCALVERSION if the profile says the flashed kernel
# carries a suffix this checkout would not produce.
# `include/config/kernel.release` is cached, so sync before trusting it.
kernel_release() {
	# shellcheck disable=SC2086
	make -s $KERNEL_MAKE_ARGS syncconfig >/dev/null
	# shellcheck disable=SC2086
	make -s $KERNEL_MAKE_ARGS kernelrelease 2>/dev/null | tail -1
}
KVER="$(kernel_release)"
[ -n "$KVER" ] || KVER="$KVER_MAKEFILE"
if [ -n "${KERNEL_LOCALVERSION:-}" ]; then
	case "$KVER" in
		*"$KERNEL_LOCALVERSION")
			echo "kernel release already carries '$KERNEL_LOCALVERSION': $KVER" ;;
		*)
			echo "pinning CONFIG_LOCALVERSION=\"$KERNEL_LOCALVERSION\" to match the flashed kernel"
			# merge rather than append: .config may already carry the symbol, and
			# merge_config replaces the old value instead of duplicating it
			lvfrag="$(mktemp)"
			printf 'CONFIG_LOCALVERSION="%s"\n' "$KERNEL_LOCALVERSION" > "$lvfrag"
			scripts/kconfig/merge_config.sh -m .config "$lvfrag" >/dev/null 2>&1 || \
				printf 'CONFIG_LOCALVERSION="%s"\n' "$KERNEL_LOCALVERSION" >> .config
			rm -f "$lvfrag"
			# shellcheck disable=SC2086
			make -s $KERNEL_MAKE_ARGS olddefconfig
			KVER="$(kernel_release)"
			;;
	esac
fi
echo "kernel release (module directory): $KVER"

log "2. build the kernel image"
# `make modules` on its own cannot work in a fresh tree: modpost has no
# vmlinux.symvers yet and reports every core symbol as undefined.  Building
# vmlinux first produces it (and gives us the Image the modules belong to,
# which is worth shipping next to them).
# shellcheck disable=SC2086
make -j"$JOBS" $KERNEL_MAKE_ARGS Image
KIMAGE="$KBOUT/arch/arm64/boot/Image"
[ -s "$KIMAGE" ] || die "kernel Image missing"
# shellcheck disable=SC2086
make -j"$JOBS" $KERNEL_MAKE_ARGS "mediatek/${DTS%.dts}.dtb"

log "2b. build modules"
# shellcheck disable=SC2086
make -j"$JOBS" $KERNEL_MAKE_ARGS modules
fi

# ---------------------------------------------------------------- userspace
log "3. bootstrap $DISTRO_NAME/$SUITE ($ARCH)"
distro_bootstrap "$ROOTFS" "$SUITE" "$ARCH" "$MIRROR" "$JOBS"
distro_configure "$ROOTFS" "$SUITE"

log "4. install kernel modules"
if [ "$ROOTFS_ONLY" = 0 ]; then
# With LLVM=1 the kernel strips modules with llvm-strip; if the tool is absent,
# ship them unstripped rather than failing after a long build.
MOD_STRIP=1
case " $KERNEL_MAKE_ARGS " in
	*" LLVM="*)
		if ! command -v llvm-strip >/dev/null 2>&1; then
			echo "warning: llvm-strip not found; installing modules unstripped"
			MOD_STRIP=""
		fi ;;
esac
# shellcheck disable=SC2086
make $KERNEL_MAKE_ARGS INSTALL_MOD_PATH="$ROOTFS" ${MOD_STRIP:+INSTALL_MOD_STRIP=1} modules_install
# The directory modules_install actually used is the truth: if it differs from
# what we expected, the image would boot without modules, so say so loudly.
INSTALLED_MODULE_DIR="$(ls "$ROOTFS/lib/modules" 2>/dev/null | head -1)"
if [ -n "$INSTALLED_MODULE_DIR" ] && [ "$INSTALLED_MODULE_DIR" != "$KVER" ]; then
	die "modules directory $INSTALLED_MODULE_DIR != kernel release $KVER"
elif [ -z "$INSTALLED_MODULE_DIR" ]; then
	die "no modules were installed into the rootfs"
fi
echo "modules installed for kernel release: $KVER"
rm -f "$ROOTFS/lib/modules/$KVER/build" "$ROOTFS/lib/modules/$KVER/source"
depmod -b "$ROOTFS" "$KVER"
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
distro_finalize "$ROOTFS"
rm -rf "$ROOTFS/var/cache/apt"/* "$ROOTFS/var/lib/apt/lists"/* 2>/dev/null || true
rm -rf "$ROOTFS/tmp"/* 2>/dev/null || true
install -d -m 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"

log "8b. validate image contracts"
checks=("$ROOTFS" --device "$DEVICE" --user "$DEFAULT_USER" --init "$INIT_SYSTEM"
	--ui "$UI" --kernel "$KVER" --ssh-unit "${SSH_UNIT:-ssh.service}"
	--phosh-unit "${PHOSH_UNIT:-greetd.service}")
[ -z "$ROOT_PASSWORD" ] || checks+=(--allow-root-password)
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

# What the kernel has to report for these modules to be found: if `uname -r` on
# the device differs from this, the modules will not load.
cat > "$OUT/KERNEL-INFO-$DEVICE$NAME_SUFFIX-$DISTRO_NAME.txt" <<EOF
device:          $DEVICE
distribution:    $DISTRO_NAME/$SUITE
kernel commit:   ${KERNEL_COMMIT:-none (userspace-only, not deployable)}
kernel branch:   $KERNEL_REF
kernel release:  $KVER
modules live in: /lib/modules/$KVER
kernel config:   $CONFIG_SOURCE
make args:       ${KERNEL_MAKE_ARGS:-<none>}
local version:   ${KERNEL_LOCALVERSION:-<none>}

check on the device:  uname -r     # must print $KVER
EOF
cat "$OUT/KERNEL-INFO-$DEVICE$NAME_SUFFIX-$DISTRO_NAME.txt"

# Ship the kernel these modules were built against, so the pair cannot be mixed
# up.  The DTB may be embedded in the Image (the pearl branch does that).
if [ -f "$KBOUT/arch/arm64/boot/Image" ]; then
	cp "$KBOUT/arch/arm64/boot/Image" "$OUT/Image-$DEVICE$NAME_SUFFIX-$DISTRO_NAME"
fi
DTB="${DTS%.dts}.dtb"
if [ -f "$KBOUT/arch/arm64/boot/dts/mediatek/$DTB" ]; then
	cp "$KBOUT/arch/arm64/boot/dts/mediatek/$DTB" "$OUT/dtb-$DEVICE$NAME_SUFFIX-$DISTRO_NAME.dtb"
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
[ "$ROOTFS_ONLY" = 0 ] || { echo "userspace-only validation complete; no kernel or flashable image"; exit 0; }
cat <<EOF
device    : $DEVICE  ($PLATFORM_NAME)
kernel    : $KERNEL_REF = $KVER
config    : $CONFIG_SOURCE
rootfs    : $DISTRO_NAME/$SUITE $ARCH
userdata  : $USERDATA_PART (${NVDATA_PART:+nvdata $NVDATA_PART})
timestamp : $TS

Deployment erases userdata. Use the device-specific boot/recovery procedure.
This builder never flashes partitions. Keep Image, DTB and modules as a pair.
EOF
