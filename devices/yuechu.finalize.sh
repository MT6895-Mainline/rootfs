# shellcheck shell=bash
# yuechu rootfs finalize hook, sourced by distro_finalize (distros/common.sh).
#
# The overlay only copies regular files, so the enable/mask symlinks and the
# resolv.conf link are made here.

device_finalize() {
	local root="$1"

	# No suspend path is validated on this board yet (WiFi does not come back).
	systemctl --root="$root" mask sleep.target suspend.target hibernate.target 		hybrid-sleep.target suspend-then-hibernate.target

	# USB NCM gadget (169.254.42.1) so the phone is reachable over the cable
	# before WiFi is configured.
	systemctl --root="$root" enable yuechu-usbnet.service

	# NetworkManager hands DNS to systemd-resolved (98-yuechu-dns.conf), so
	# the WiFi and cellular servers stay per link.
	rm -f "$root/etc/resolv.conf"
	ln -s /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
}
