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
	[ "$UI" != phosh ] || packages="$packages mobian-phosh"
	distro_install_packages "$root" "$packages"
	distro_common_configure "$root"
}
