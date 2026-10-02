#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DISTRO_HOST_TOOLS="mmdebstrap chroot unshare systemctl"
DISTRO_DEFAULT_SUITE=trixie
INIT_SYSTEM=systemd
ADMIN_GROUP=sudo
SSH_UNIT=ssh.service
VAAPI_BUILD_PACKAGES="build-essential libva-dev pkg-config"

distro_bootstrap() {
	local root="$1" suite="$2" arch="$3" mirror="$4"
	local packages="${PACKAGES_CORE:-} ${PACKAGES_EXTRA:-} ca-certificates bash passwd"
	mmdebstrap --architectures="$arch" --variant=important \
		--components=main,contrib,non-free-firmware \
		--include="$(tr ' ' ',' <<< "$packages" | tr -s ',')" \
		--aptopt='Apt::Install-Recommends "false"' \
		--aptopt='Acquire::Retries "3"' \
		"$suite" "$root" "${mirror:-https://deb.debian.org/debian}"
	install -m 0644 /etc/resolv.conf "$root/etc/resolv.conf"
}

distro_install_packages() {
	local root="$1"; shift
	distro_chroot "$root" apt-get update
	# Lists come only from checked-in backends/profiles.
	# shellcheck disable=SC2086
	distro_chroot "$root" apt-get install -y --no-install-recommends $*
}

distro_configure() {
	local root="$1"
	[ "$UI" != phosh ] || distro_install_packages "$root" "phosh phoc pipewire wireplumber"
	distro_common_configure "$root"
}
