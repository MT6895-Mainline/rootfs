#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Ubuntu backend.  arm64 packages come from ports.ubuntu.com; the CI runner
# is Ubuntu itself, so mmdebstrap trusts the host ubuntu-archive-keyring that
# covers every suite we accept here.
DISTRO_HOST_TOOLS="mmdebstrap chroot unshare systemctl curl"
DISTRO_DEFAULT_SUITE=noble
INIT_SYSTEM=systemd
ADMIN_GROUP=sudo
SSH_UNIT=ssh.service
PHOSH_UNIT=gdm3.service
VAAPI_BUILD_PACKAGES="build-essential libva-dev libdrm-dev pkg-config"
BASEBAND_BUILD_PACKAGES="build-essential meson ninja-build pkg-config gettext xsltproc python3 \
libglib2.0-dev libdbus-1-dev libgudev-1.0-dev libudev-dev libpolkit-gobject-1-dev libsystemd-dev"
UBUNTU_PORTS_MIRROR="${UBUNTU_PORTS_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"

distro_bootstrap() {
	local root="$1" suite="$2" arch="$3" mirror="$4"
	local packages="${PACKAGES_CORE:-} ${PACKAGES_EXTRA:-} ca-certificates bash passwd"
	mmdebstrap --architectures="$arch" --variant=important \
		--components=main,restricted,universe,multiverse \
		--include="$(tr ' ' ',' <<< "$packages" | tr -s ',')" \
		--aptopt='Apt::Install-Recommends "false"' \
		--aptopt='Acquire::Retries "3"' \
		--mirror="${mirror:-$UBUNTU_PORTS_MIRROR}" \
		"$suite" "$root"
	install -m 0644 /etc/resolv.conf "$root/etc/resolv.conf"
}

distro_install_packages() {
	local root="$1"; shift
	distro_chroot "$root" apt-get update
	# shellcheck disable=SC2086
	distro_chroot "$root" apt-get install -y --no-install-recommends $*
}

distro_configure() {
	local root="$1"
	# Desktop matrix.  phosh runs through GDM's Wayland session on Ubuntu;
	# the desktop UIs use the display manager named here.
	case "$UI" in
		console) ;;
		phosh)
			distro_install_packages "$root" "phosh phosh-mobile-settings phoc squeekboard" ;;
		gnome)
			DISPLAY_MANAGER_UNIT=gdm3.service
			distro_install_packages "$root" "gnome-core gnome-shell gdm3 gnome-tweaks" ;;
		kde)
			DISPLAY_MANAGER_UNIT=sddm.service
			distro_install_packages "$root" "kde-plasma-desktop plasma-nm sddm" ;;
		kdeplasmamobile)
			DISPLAY_MANAGER_UNIT=sddm.service
			distro_install_packages "$root" "plasma-mobile plasma-nm sddm" ;;
		xfce)
			DISPLAY_MANAGER_UNIT=lightdm.service
			distro_install_packages "$root" "xfce4 xfce4-goodies lightdm lightdm-gtk-greeter" ;;
		*)
			die "ubuntu backend does not know --ui $UI" ;;
	esac
	[ "$UI" = console ] || distro_install_packages "$root" "pipewire wireplumber"
	distro_common_configure "$root"
}
