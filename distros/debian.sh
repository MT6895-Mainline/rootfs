#!/usr/bin/env bash
# Debian backend for build.sh
#
# Called by build.sh as:
#   distro_bootstrap <rootfs> <suite> <arch> <mirror> <jobs>
#   distro_configure <rootfs> <suite>
#
# Foreign-arch bootstrapping needs qemu-user-static registered in binfmt_misc
# on the build host (the CI workflow installs qemu-user-static +
# binfmt-support; on Debian/Ubuntu hosts that is enough).

distro_bootstrap() {
	local rootfs="$1" suite="$2" arch="$3" mirror="$4" jobs="$5"
	local components="${DEBIAN_COMPONENTS:-main,contrib,non-free-firmware}"
	local pkgs
	pkgs="$(printf '%s %s' "${PACKAGES_CORE:-}" "${PACKAGES_EXTRA:-}" \
		| tr -s ' ' | sed 's/^ //; s/ $//')"

	if ! [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
		echo "warning: qemu-aarch64 binfmt handler not registered;" \
		     "install qemu-user-static + binfmt-support" >&2
	fi

	mmdebstrap \
		--architectures="$arch" \
		--variant=important \
		--components="$components" \
		--include="$pkgs" \
		--aptopt='Apt::Install-Recommends "false"' \
		--aptopt='Acquire::Retries "3"' \
		--dpkgopt='path-exclude=/usr/share/doc/*' \
		--dpkgopt='path-exclude=/usr/share/man/*' \
		--dpkgopt='path-exclude=/usr/share/locale/*' \
		${mirror:+--mirror="$mirror"} \
		"$suite" "$rootfs"

	# a real init system is mandatory on these devices
	if ! [ -e "$rootfs/usr/lib/systemd/systemd" ]; then
		echo "error: systemd missing in the bootstrapped rootfs" >&2
		return 1
	fi
}

distro_configure() {
	local rootfs="$1" suite="$2"
	local user="${DEFAULT_USER:-mobian}"

	# locale + timezone (no interactive tzdata)
	chroot "$rootfs" /bin/sh -c '
		set -e
		echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
		locale-gen >/dev/null 2>&1 || true
		ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		echo Asia/Shanghai > /etc/timezone
	' || true

	# default user (same convention as the existing pearl images)
	if ! chroot "$rootfs" /bin/sh -c "id $user" >/dev/null 2>&1; then
		chroot "$rootfs" /bin/sh -c "
			set -e
			useradd -m -s /bin/bash -G sudo,audio,video,render,plugdev,netdev $user
			passwd -d $user
		" || echo "warning: could not create user $user"
	fi

	# enable the baseline services; the per-device overlay adds quirks
	for unit in systemd-networkd systemd-resolved ssh NetworkManager \
		    systemd-timesyncd bluetooth ModemManager iio-sensor-proxy; do
		chroot "$rootfs" systemctl enable "$unit" >/dev/null 2>&1 || true
	done

	# MT6895-Mainline: first boot resizes the root filesystem to the partition
	chroot "$rootfs" systemctl enable mt6895-firstboot.service >/dev/null 2>&1 || true

	cat > "$rootfs/etc/apt/sources.list" <<EOF
# MT6895-Mainline rootfs ($suite).  non-free-firmware is enabled so that
# redistributable firmware (e.g. linux-firmware) can be pulled, but the
# device-specific vendor blobs are NOT shipped in these images.
deb http://deb.debian.org/debian $suite main contrib non-free-firmware
deb http://deb.debian.org/debian $suite-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security $suite-security main contrib non-free-firmware
EOF
}
