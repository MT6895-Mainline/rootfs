#!/usr/bin/env bash
#
# Collect the vendor firmware needed by an MT6895-Mainline rootfs.
#
# The blobs are proprietary: this tool exists so that each user extracts them
# from their *own* device.  The resulting tarball is passed to the rootfs build
# (build.sh --firmware DIR, or the firmware_url input of the CI workflow).
#
# Two sources are supported:
#   --from-rootfs      tar the firmware set of a device that already boots
#                      mainline Linux (simplest, and exactly the working set)
#   --from-partitions  dd the vendor firmware partitions of a stock device
#                      (for a first bring-up, where no mainline rootfs exists)
#
# Usage (run on the device, as root):
#   ./extract-firmware.sh --from-rootfs /tmp/firmware.tar.zst
#   ./extract-firmware.sh --from-partitions /tmp/vendor-firmware.tar.zst
#
set -euo pipefail

MODE=""
OUT=""
PARTS="scp_a sspm_a mcupm_a gpueb_a spmfw_a pi_img_a connsys_wifi_a connsys_bt_a md1img_a"

while [ $# -gt 0 ]; do
	case "$1" in
		--from-rootfs) MODE=rootfs; shift ;;
		--from-partitions) MODE=parts; shift ;;
		--partitions) PARTS="$2"; shift 2 ;;
		--out) OUT="$2"; shift 2 ;;
		-h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) OUT="$1"; shift ;;
	esac
done

[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }
[ -n "$MODE" ] || { echo "pick --from-rootfs or --from-partitions" >&2; exit 1; }
[ -n "$OUT" ] || OUT="/tmp/mt6895-firmware-$(date -u +%Y%m%d).tar.zst"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ "$MODE" = "rootfs" ]; then
	echo "collecting /lib/firmware from the running system"
	[ -d /lib/firmware ] || { echo "no /lib/firmware" >&2; exit 1; }
	mkdir -p "$STAGE/firmware"
	# everything except the freely redistributable linux-firmware content
	# would be safer, but we cannot tell them apart reliably: keep it all and
	# let the user decide what to publish.
	if command -v rsync >/dev/null 2>&1; then
		rsync -a /lib/firmware/ "$STAGE/firmware/"
	else
		cp -a /lib/firmware/. "$STAGE/firmware/"
	fi
	du -sh "$STAGE/firmware"
else
	echo "dumping vendor firmware partitions"
	mkdir -p "$STAGE/partitions"
	for p in $PARTS; do
		dev="/dev/disk/by-partlabel/$p"
		if [ ! -e "$dev" ]; then
			echo "  skip $p (absent)"
			continue
		fi
		echo "  dd $p"
		dd if="$dev" of="$STAGE/partitions/$p.img" bs=1M status=none || \
			echo "  warning: $p dump failed"
	done
	{
		echo "# MT6895-Mainline vendor firmware dump"
		echo "# date: $(date -u)"
		echo "# device: $(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')"
		echo "# partitions:"
		ls -l "$STAGE/partitions"
		echo
		echo "# NOTE: these are raw vendor partitions.  Splitting the MTK"
		echo "# firmware containers (scp/sspm/mcupm/gpueb/spmfw) into the"
		echo "# filenames the mainline drivers expect is device specific and"
		echo "# still has to be done by hand (or with a per-device script)."
	} > "$STAGE/README"
	du -sh "$STAGE/partitions"
fi

echo "packing $OUT"
tar --numeric-owner -C "$STAGE" -I 'zstd -19 -T0' -cpf "$OUT" .
ls -l "$OUT"
echo "pass this file to:  build.sh --firmware <dir>"
