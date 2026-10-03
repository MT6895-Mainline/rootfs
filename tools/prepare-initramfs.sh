#!/usr/bin/env bash
# Prepare an immutable source-built archive; never flash or modify the kernel.
set -euo pipefail
[ "$#" = 5 ] || { echo 'usage: prepare-initramfs.sh REPO COMMIT DEVICE OUTPUT_DIR FIRMWARE_DIR' >&2; exit 2; }
repo="$1" commit="$2" device="$3" output="$4" firmware="$5"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'initramfs requires a full commit ID' >&2; exit 2; }
[ "$device" = qqcandy ] || { echo 'no reviewed embedded initramfs contract for this device' >&2; exit 2; }
[ ! -e "$output" ] || { echo 'initramfs output directory already exists' >&2; exit 2; }
[ -z "$firmware" ] || firmware="$(realpath -e "$firmware")"
mkdir -p "$output"
output="$(realpath "$output")"
git clone --no-checkout -- "$repo" "$output/source"
git -C "$output/source" checkout --detach "$commit"
[ "$(git -C "$output/source" rev-parse HEAD)" = "$commit" ]
make -C "$output/source" DEVICE="$device" FIRMWARE_DIR="$firmware"
root="$output/source/build/$device/root"
test "$root/init" -ef "$root/xinit"
readelf -h "$root/init" | grep -q 'Machine:.*AArch64'
if readelf -l "$root/init" | grep -q INTERP; then
	echo 'initramfs init must be static' >&2
	exit 1
fi
archive="$output/initramfs-$device.cpio"
cp "$output/source/initramfs-$device.cpio" "$archive"
list="$(cpio -it < "$archive" 2>/dev/null)"
grep -qx init <<< "$list"
grep -qx xinit <<< "$list"
python3 - "$repo" "$commit" "$device" "$archive" "$root/init" "$output/manifest.json" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
repo, commit, device, archive, init, output = sys.argv[1:]
data = {"schema": 1, "device": device, "repository": repo, "commit": commit,
        "archive_sha256": hashlib.sha256(Path(archive).read_bytes()).hexdigest(),
        "init_sha256": hashlib.sha256(Path(init).read_bytes()).hexdigest(),
        "entries": ["/init", "/xinit"], "boot_validated": False}
Path(output).write_text(json.dumps(data, indent=2) + "\n")
PY
