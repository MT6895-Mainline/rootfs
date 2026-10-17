#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Fedora backend.  Fedora has no debootstrap-style entry point; the supported
# offline way in is the official "Container Base" aarch64 image (a full dnf
# userspace), driven through the same chroot as every other backend.  The
# "suite" is the Fedora release (41, 42, ...).
DISTRO_HOST_TOOLS="curl bsdtar chroot unshare systemctl gpg"
DISTRO_DEFAULT_SUITE=42
INIT_SYSTEM=systemd
ADMIN_GROUP=wheel
SSH_UNIT=sshd.service
PHOSH_UNIT=gdm.service
VAAPI_BUILD_PACKAGES="gcc gcc-c++ make libva-devel libdrm-devel pkgconfig"
BASEBAND_BUILD_PACKAGES="gcc gcc-c++ make meson ninja-build pkgconfig gettext libxslt \
glib2-devel dbus-devel libgudev-devel systemd-devel polkit-devel"
FEDORA_MIRROR="${FEDORA_MIRROR:-https://download.fedoraproject.org/pub/fedora/linux}"

fedora_container_url() {
	local suite="$1" index
	index="$(curl -fsSL --retry 3 \
		"$FEDORA_MIRROR/releases/$suite/Container/aarch64/images/")" || return 1
	printf '%s' "$index" |
		grep -oE 'Fedora-Container-Base-[0-9]+(-[0-9.]+)?\.aarch64\.tar\.xz' |
		sort -u | tail -1 | sed "s|^|$FEDORA_MIRROR/releases/$suite/Container/aarch64/images/|"
}

distro_bootstrap() {
	local root="$1" suite="$2" arch="$3"
	local archive="$WORK/fedora-container-$suite.tar.xz" url
	[ "$arch" = arm64 ] || die "the fedora backend supports arm64 only"
	url="$(fedora_container_url "$suite")" ||
		die "cannot locate the Fedora $suite container image"
	echo "fedora container image: $url"
	curl -fL --retry 3 "$url" -o "$archive"
	# The archive carries '<release>/rootfs/...' - strip both prefixes.
	bsdtar -xpf "$archive" -C "$root" --strip-components=2
	[ -x "$root/usr/bin/dnf" ] || die "fedora container image has no dnf"
	rm -f "$root/etc/resolv.conf"
	install -m 0644 /etc/resolv.conf "$root/etc/resolv.conf"
}

distro_install_packages() {
	local root="$1"; shift
	# WORKAROUND: QEMU user emulation cannot provide the seccomp/Landlock
	# filters dnf enables; build-only, the deployed configuration is untouched.
	# shellcheck disable=SC2086
	distro_chroot "$root" dnf -y --setopt=install_weak_deps=False \
		--setopt=tsflags=nodocs install $*
}

distro_configure() {
	local root="$1"
	distro_install_packages "$root" "systemd systemd-udev openssh-server sudo kmod \
		networkmanager bluez bluez-utils modemmanager iio-sensor-proxy \
		alsa-ucm-conf alsa-utils e2fsprogs iproute2 shadow passwd"
	# Desktop matrix.  phosh runs through GDM's Wayland session (like the
	# arch backend); the desktop UIs use the display manager named here.
	case "$UI" in
		console) ;;
		phosh)
			distro_install_packages "$root" "phosh phoc squeekboard gnome-keyring gnome-settings-daemon gdm" ;;
		gnome)
			DISPLAY_MANAGER_UNIT=gdm.service
			distro_install_packages "$root" "gnome-shell gnome-session gdm gnome-tweaks" ;;
		kde)
			DISPLAY_MANAGER_UNIT=sddm.service
			distro_install_packages "$root" "plasma-desktop plasma-nm sddm" ;;
		kdeplasmamobile)
			DISPLAY_MANAGER_UNIT=sddm.service
			distro_install_packages "$root" "plasma-mobile sddm" ;;
		xfce)
			DISPLAY_MANAGER_UNIT=lightdm.service
			distro_install_packages "$root" "xfce4-session xfce4-panel xfwm4 xfdesktop thunar \
				lightdm lightdm-gtk-greeter" ;;
		*)
			die "fedora backend does not know --ui $UI" ;;
	esac
	[ "$UI" = console ] || distro_install_packages "$root" "pipewire pipewire-pulseaudio wireplumber"
	distro_common_configure "$root"
}
