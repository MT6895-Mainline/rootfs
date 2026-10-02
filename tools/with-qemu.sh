#!/usr/bin/env bash
# Private binfmt namespace: do not replace Waydroid or host QEMU handlers.
set -euo pipefail
if [ "${1:-}" != --inside ]; then
	[ "$(id -u)" = 0 ] || { echo "Run with sudo" >&2; exit 1; }
	exec unshare --user --map-users=0:0:65536 --map-groups=0:0:65536 \
		--mount --pid --mount-proc --fork "$0" --inside "$@"
fi
shift
mount --make-rprivate /
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
qemu="$(command -v qemu-aarch64-static)"
magic='\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00'
mask='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
printf '%s\n' ":mt6895-rootfs-aarch64:M::$magic:$mask:$qemu:F" > /proc/sys/fs/binfmt_misc/register
exec "$@"
