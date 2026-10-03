#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Upstream tool/package identifiers are still postmarketOS during rebranding.
DISTRO_HOST_TOOLS="python3 git chroot unshare kpartx openssl"
DISTRO_DEFAULT_SUITE=edge
INIT_SYSTEM=openrc
ADMIN_GROUP=wheel
VAAPI_BUILD_PACKAGES="build-base libva-dev libdrm-dev linux-headers pkgconf"
BASEBAND_BUILD_PACKAGES="build-base meson ninja pkgconf gettext-dev libxslt python3 glib-dev dbus-dev libgudev-dev eudev-dev polkit-dev"
PMBOOTSTRAP_COMMIT=b31c99504d70ec7b8e2e6e47eb84262bd7114e94
PMAPORTS_COMMIT=5f7529d92dcc1c41b2bfb6a7b3e09df8fafc0a34
# _pmb_recommends from the pinned Phosh/GNOME Mobile/GNOME/base UI APKBUILDs.
# Direct apk bootstrap does not expand pmbootstrap's recommendations.
NURA_PHOSH_RECOMMENDS="phosh-mobile-settings phosh-tour \
calls chatty lpa-gtk mobile-config-firefox postmarketos-tweaks-setting-definitions ttyescape vvmplayer \
cups decibels firefox-esr flatpak fprintd g4music gnome-calculator gnome-calendar \
gnome-clocks gnome-console gnome-contacts gnome-maps gnome-text-editor gnome-user-share \
gnome-weather gst-libav gst-plugins-bad gst-plugins-good gst-plugins-rs-dav1d gvfs-full \
loupe nautilus papers rygel showtime snapshot tuned-ppd \
font-droid font-droid-nonlatin font-twemoji lang"

pmb() {
	python3 "$WORK/pmbootstrap/pmbootstrap.py" --as-root --details-to-stdout \
		--config "$WORK/pmbootstrap.cfg" --work "$WORK/pmb-work" \
		--aports "$WORK/pmaports" "$@"
}

distro_bootstrap() {
	local root="$1" suite="$2"
	[ "$suite" = edge ] || die "the pinned Nura backend supports --suite edge only"
	if [ "$(uname -m)" != aarch64 ]; then
		arch-test arm64
		[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] ||
			die "register the host qemu-aarch64 handler before using pmbootstrap"
	fi
	git clone --depth 1 "${PMBOOTSTRAP_REPO:-https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git}" "$WORK/pmbootstrap"
	git -C "$WORK/pmbootstrap" fetch --depth 1 origin "$PMBOOTSTRAP_COMMIT"
	git -C "$WORK/pmbootstrap" checkout --detach "$PMBOOTSTRAP_COMMIT"
	git clone --depth 1 "${PMAPORTS_REPO:-https://gitlab.postmarketos.org/postmarketOS/pmaports.git}" "$WORK/pmaports"
	git -C "$WORK/pmaports" fetch --depth 1 origin "$PMAPORTS_COMMIT"
	git -C "$WORK/pmaports" checkout --detach "$PMAPORTS_COMMIT"
	# pmbootstrap identifies its upstream by URL, also when using a local cache.
	git -C "$WORK/pmaports" remote set-url origin https://gitlab.postmarketos.org/postmarketOS/pmaports.git
	# Use upstream ARM64 bootstrap architecture, not its QEMU kernel/boot recipe.
	cat > "$WORK/pmbootstrap.cfg" <<EOF
[pmbootstrap]
device = qemu-aarch64
user = $DEFAULT_USER
ui = console
service_manager = openrc
[mirrors]
alpine = https://dl-cdn.alpinelinux.org/alpine/
pmaports = https://mirror.postmarketos.org/postmarketos/
EOF
	mkdir -p "$WORK/pmb-work"
	# Work directory format required by the pinned pmbootstrap 3.11.1.
	printf '8\n' > "$WORK/pmb-work/version"
	pmb chroot -r -- apk add postmarketos-base postmarketos-base-openrc \
		postmarketos-base-nofde postmarketos-base-sudo shadow bash \
		networkmanager networkmanager-openrc bluez bluez-openrc \
		modemmanager modemmanager-openrc iio-sensor-proxy alsa-ucm-conf \
		alsa-utils e2fsprogs util-linux kmod ca-certificates
	if [ "$UI" = phosh ]; then
		# Stevia's main package currently omits its split runtime schemas.
		pmb chroot -r -- apk add postmarketos-ui-phosh postmarketos-ui-phosh-openrc stevia-schemas
		# shellcheck disable=SC2086
		pmb chroot -r -- apk add $NURA_PHOSH_RECOMMENDS
	fi
	# Upstream shutdown unregisters ALL host QEMU handlers, even pre-existing
	# ones. Only detach this build's mounts, retaining host interpreter state.
	python3 "$HERE/tools/unmount-tree.py" "$WORK/pmb-work"
	cp -a "$WORK/pmb-work/chroot_rootfs_qemu-aarch64/." "$root/"
	# Keys were bind-mounted by pmbootstrap; retain the public trust anchors.
	install -d "$root/etc/apk/keys"
	cp -a "$WORK/pmb-work/config_apk_keys/." "$root/etc/apk/keys/"
	sed -i '\|^/mnt/pmbootstrap/|d' "$root/etc/apk/repositories"
	rm -f "$root/in-pmbootstrap" "$root/etc/resolv.conf"
	install -m 0644 /etc/resolv.conf "$root/etc/resolv.conf"
	cat > "$root/etc/deviceinfo" <<EOF
deviceinfo_name="$PLATFORM_NAME"
deviceinfo_codename="$DEVICE"
deviceinfo_arch="aarch64"
deviceinfo_chassis="handset"
EOF
	if [ "$UI" = phosh ]; then
		install -d "$root/usr/share/mt6895-build"
		printf '%s\n' "$PMAPORTS_COMMIT" "$NURA_PHOSH_RECOMMENDS" > \
			"$root/usr/share/mt6895-build/nura-phosh-recommends.txt"
	fi
}

distro_install_packages() {
	local root="$1"; shift
	# shellcheck disable=SC2086
	distro_chroot "$root" apk add --no-interactive $*
}

distro_configure() {
	local root="$1" service
	distro_common_configure "$root"
	for service in networkmanager bluetooth modemmanager sshd; do
		distro_chroot "$root" rc-update add "$service" default
	done
}

distro_finalize() {
	local root="$1"
	rm -f "$root/etc/systemd/system/mt6895-firstboot.service"
	distro_chroot "$root" rc-update add mt6895-firstboot default
	# OpenRC's D-Bus start hook generates a missing ID, not an empty one.
	rm -f "$root/etc/machine-id" "$root/var/lib/dbus/machine-id" \
		"$root/etc/resolv.conf" "$root/etc/ssh/ssh_host_"*
	ln -s /run/NetworkManager/resolv.conf "$root/etc/resolv.conf"
	find "$root/var/cache" -type f -delete
}
