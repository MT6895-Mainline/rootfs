#!/usr/bin/env bash
#
# Install a vendor firmware tarball into a running MT6895-Mainline rootfs.
# Run on the device, as root:
#
#   ./install-firmware.sh firmware.tar.zst
#
# The archive layout is the one produced by tools/extract-firmware.sh
# ("firmware/" for a rootfs capture, "partitions/" for a raw partition dump).
set -euo pipefail

ARCHIVE="${1:?usage: install-firmware.sh <firmware.tar.zst>}"
[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }
[ -f "$ARCHIVE" ] || { echo "no such file: $ARCHIVE" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
tar -xf "$ARCHIVE" -C "$STAGE"

if [ -d "$STAGE/firmware" ]; then
	echo "installing firmware/ into /lib/firmware"
	install -d /lib/firmware
	cp -a "$STAGE/firmware/." /lib/firmware/
elif [ -d "$STAGE/partitions" ]; then
	echo "raw vendor partitions found in the archive:"
	ls -l "$STAGE/partitions"
	echo
	echo "These are raw MTK partitions; they cannot be installed as firmware"
	echo "files directly.  See $STAGE/README for what still has to be split."
	echo "Keeping them in /var/lib/mt6895-vendor/ for inspection."
	install -d /var/lib/mt6895-vendor
	cp -a "$STAGE/partitions/." /var/lib/mt6895-vendor/
else
	echo "unexpected archive layout" >&2
	ls -R "$STAGE" | head -20 >&2
	exit 1
fi

echo "done; reboot to let the drivers pick the firmware up"
