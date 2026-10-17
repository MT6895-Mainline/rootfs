#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/debian.sh"

distro_configure() {
	local root="$1" suite="$2"
	# Establish trust through Debian's authenticated archive first.
	distro_install_packages "$root" mobian-archive-keyring
	[ -f "$root/etc/apt/sources.list.d/mobian.sources" ] ||
		die "mobian-archive-keyring did not install mobian.sources"
	sed -i "s/^Suites: .*/Suites: $suite/" "$root/etc/apt/sources.list.d/mobian.sources"
	printf 'Package: *\nPin: release o=Mobian\nPin-Priority: 700\n' \
		> "$root/etc/apt/preferences.d/00-mobian-priority"
	local packages=mobian-base
	# Desktop matrix: phosh is the Mobian session; the other UIs come from
	# the Debian/Mobian archive underneath and select their own DM.
	case "$UI" in
		console) ;;
		phosh) packages="$packages mobian-phosh phrog" ;;
		gnome)
			DISPLAY_MANAGER_UNIT=gdm3.service
			packages="$packages gnome-core gnome-shell gdm3 gnome-tweaks" ;;
		kde)
			DISPLAY_MANAGER_UNIT=sddm.service
			packages="$packages kde-plasma-desktop plasma-nm sddm" ;;
		kdeplasmamobile)
			DISPLAY_MANAGER_UNIT=sddm.service
			packages="$packages plasma-mobile plasma-nm sddm" ;;
		xfce)
			DISPLAY_MANAGER_UNIT=lightdm.service
			packages="$packages xfce4 xfce4-goodies lightdm lightdm-gtk-greeter" ;;
		*)
			die "mobian backend does not know --ui $UI" ;;
	esac
	[ "$UI" = console ] || packages="$packages pipewire wireplumber"
	distro_install_packages "$root" "$packages"
	distro_common_configure "$root"
}
