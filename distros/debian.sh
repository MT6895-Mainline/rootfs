#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DISTRO_HOST_TOOLS="mmdebstrap chroot unshare systemctl curl gpg"
DISTRO_DEFAULT_SUITE=trixie
INIT_SYSTEM=systemd
ADMIN_GROUP=sudo
SSH_UNIT=ssh.service
PHOSH_UNIT=greetd.service
VAAPI_BUILD_PACKAGES="build-essential libva-dev libdrm-dev pkg-config"
BASEBAND_BUILD_PACKAGES="build-essential meson ninja-build pkg-config gettext xsltproc python3 \
libglib2.0-dev libdbus-1-dev libgudev-1.0-dev libudev-dev libpolkit-gobject-1-dev libsystemd-dev"

debian_keyring() {
	local dir="$WORK/debian-trust" file fingerprint actual
	install -d -m 0700 "$dir"
	gpg --homedir "$dir" --batch --import /usr/share/keyrings/debian-archive-keyring.gpg
	# Full fingerprints are published by Debian ftp-master, independently of
	# the archive mirror. Ubuntu 24.04's keyring predates the Trixie keys.
	while read -r file fingerprint; do
		curl -fL --retry 3 "https://ftp-master.debian.org/keys/$file.asc" -o "$dir/$file.asc"
		actual="$(gpg --homedir "$dir" --batch --with-colons --show-keys "$dir/$file.asc" |
			awk -F: '$1 == "fpr" { print $10; exit }')"
		[ "$actual" = "$fingerprint" ] || die "Debian archive key fingerprint mismatch"
		gpg --homedir "$dir" --batch --import "$dir/$file.asc"
	done <<'EOF'
archive-key-13 04B54C3CDCA79751B16BC6B5225629DF75B188BD
archive-key-13-security 5E04A1E3223A19A20706E20F9904613D4CCE68C6
release-13 41587F7DB8C774BCCF131416762F67A0B2C39DE4
EOF
	gpg --homedir "$dir" --batch --output "$dir/archive.gpg" --export
}

distro_bootstrap() {
	local root="$1" suite="$2" arch="$3" mirror="$4"
	local packages="${PACKAGES_CORE:-} ${PACKAGES_EXTRA:-} ca-certificates bash passwd"
	local sources=("${mirror:-https://deb.debian.org/debian}")
	case "$suite" in
		trixie|bookworm|bullseye)
			sources+=("deb https://security.debian.org/debian-security $suite-security main contrib non-free-firmware"
				"deb ${mirror:-https://deb.debian.org/debian} $suite-updates main contrib non-free-firmware") ;;
	esac
	debian_keyring
	mmdebstrap --architectures="$arch" --variant=important \
		--keyring="$WORK/debian-trust/archive.gpg" \
		--components=main,contrib,non-free-firmware \
		--include="$(tr ' ' ',' <<< "$packages" | tr -s ',')" \
		--aptopt='Apt::Install-Recommends "false"' \
		--aptopt='Acquire::Retries "3"' \
		"$suite" "$root" "${sources[@]}"
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
	[ "$UI" != phosh ] || distro_install_packages "$root" "phosh-core phrog wireplumber"
	distro_common_configure "$root"
}
