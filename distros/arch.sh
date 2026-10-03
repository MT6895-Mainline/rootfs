#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DISTRO_HOST_TOOLS="curl bsdtar gpg chroot unshare systemctl"
DISTRO_DEFAULT_SUITE=rolling
INIT_SYSTEM=systemd
ADMIN_GROUP=wheel
SSH_UNIT=sshd.service
PHOSH_UNIT=gdm.service
VAAPI_BUILD_PACKAGES="base-devel libva libdrm"
BASEBAND_BUILD_PACKAGES="base-devel meson ninja pkgconf gettext libxslt python glib2 glib2-devel dbus libgudev polkit systemd"
ARCH_SIGNING_KEY=68B3537F39A313B3E574D06777193F152BDBE6A6
ARCH_ROOTFS_URL="${ARCH_ROOTFS_URL:-https://de3.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"

distro_bootstrap() {
	local root="$1" suite="$2" archive="$WORK/archlinuxarm.tar.gz"
	[ "$suite" = rolling ] || die "Arch supports --suite rolling only"
	install -d -m 0700 "$WORK/gnupg"
	curl -fL --retry 3 "$ARCH_ROOTFS_URL" -o "$archive"
	curl -fL --retry 3 "$ARCH_ROOTFS_URL.sig" -o "$archive.sig"
	gpg --homedir "$WORK/gnupg" --batch --keyserver hkps://keyserver.ubuntu.com \
		--recv-keys "$ARCH_SIGNING_KEY"
	gpg --homedir "$WORK/gnupg" --batch --verify "$archive.sig" "$archive"
	bsdtar -xpf "$archive" -C "$root"
	rm -f "$root/etc/resolv.conf"
	install -m 0644 /etc/resolv.conf "$root/etc/resolv.conf"
}

distro_install_packages() {
	local root="$1"; shift
	# Never partially upgrade a rolling repository.
	# WORKAROUND: QEMU user emulation cannot provide Landlock/seccomp filters.
	# This build-only flag does not change the deployed pacman configuration.
	# shellcheck disable=SC2086
	distro_chroot "$root" pacman -Syu --disable-sandbox --needed --noconfirm $*
}

distro_configure() {
	local root="$1"
	distro_chroot "$root" pacman-key --init
	distro_chroot "$root" pacman-key --populate archlinuxarm
	# Boot is external; do not ship a generic kernel's autodetected initramfs.
	distro_chroot "$root" pacman -R --noconfirm linux-aarch64
	distro_install_packages "$root" "networkmanager bluez bluez-utils modemmanager \
		iio-sensor-proxy alsa-ucm-conf alsa-utils openssh sudo kmod e2fsprogs \
		iproute2 bash shadow"
	[ "$UI" != phosh ] || distro_install_packages "$root" \
		"phosh phoc gdm pipewire-pulse wireplumber squeekboard gnome-keyring gnome-settings-daemon"
	distro_chroot "$root" userdel -r alarm
	systemctl --root="$root" disable systemd-networkd.service
	distro_common_configure "$root"
	if [ "$UI" = phosh ]; then
		install -d -m 0700 "$root/var/lib/AccountsService/users"
		printf '[User]\nSession=phosh\nSessionType=wayland\nSystemAccount=false\n' > \
			"$root/var/lib/AccountsService/users/$DEFAULT_USER"
		chmod 0600 "$root/var/lib/AccountsService/users/$DEFAULT_USER"
	fi
}
