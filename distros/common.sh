#!/usr/bin/env bash

# Each invocation owns its mounts, including when a package hook fails.
distro_chroot() {
	local root="$1"; shift
	unshare --mount --propagation private bash -euc '
		root=$1; shift
		# libalpm needs a root mount visible in the chroot mount table.
		mount --bind "$root" "$root"
		mkdir -p "$root/dev" "$root/proc" "$root/run"
		mount -t tmpfs -o mode=0755 tmpfs "$root/dev"
		for node in null zero random urandom; do
			touch "$root/dev/$node"
			mount --bind "/dev/$node" "$root/dev/$node"
		done
		mkdir -p "$root/dev/pts" "$root/dev/shm"
		mount -t devpts devpts "$root/dev/pts"
		ln -s pts/ptmx "$root/dev/ptmx"
		ln -s /proc/self/fd "$root/dev/fd"
		ln -s fd/0 "$root/dev/stdin"
		ln -s fd/1 "$root/dev/stdout"
		ln -s fd/2 "$root/dev/stderr"
		mount -t proc proc "$root/proc"
		mount -t tmpfs tmpfs "$root/run"
		chroot "$root" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
			PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
	' bash "$root" "$@"
}

distro_enable_units() {
	local root="$1"; shift
	systemctl --root="$root" enable "$@"
}

distro_create_user() {
	local root="$1" user="${DEFAULT_USER:-user}" group
	for group in audio video render input netdev plugdev "$ADMIN_GROUP"; do
		distro_chroot "$root" getent group "$group" >/dev/null ||
			distro_chroot "$root" groupadd -r "$group"
	done
	if ! distro_chroot "$root" id "$user" >/dev/null 2>&1; then
		distro_chroot "$root" useradd -m -s /bin/bash \
			-G "$ADMIN_GROUP,audio,video,render,input,plugdev,netdev" "$user"
	fi
	distro_chroot "$root" passwd -l root
	distro_chroot "$root" passwd -l "$user"
	install -d -m 0750 "$root/etc/sudoers.d"
	printf '%%%s ALL=(ALL:ALL) ALL\n' "$ADMIN_GROUP" > "$root/etc/sudoers.d/10-mt6895"
	chmod 0440 "$root/etc/sudoers.d/10-mt6895"
	install -d "$root/etc/ssh/sshd_config.d"
	printf 'PermitRootLogin no\nPasswordAuthentication no\n' > \
		"$root/etc/ssh/sshd_config.d/10-mt6895.conf"
}

distro_common_configure() {
	local root="$1"
	distro_create_user "$root"
	if [ "$INIT_SYSTEM" = systemd ]; then
		distro_enable_units "$root" NetworkManager.service bluetooth.service \
			ModemManager.service "$SSH_UNIT"
		if [ "$UI" = phosh ]; then
			if [ -f "$root/usr/lib/systemd/system/phosh.service" ] ||
				[ -f "$root/lib/systemd/system/phosh.service" ]; then
				systemctl --root="$root" disable phosh.service
			fi
			distro_enable_units "$root" "$PHOSH_UNIT"
			systemctl --root="$root" set-default graphical.target
		fi
	fi
}

distro_finalize() {
	local root="$1"
	# Debian otherwise treats the OpenRC script as a same-named SysV service.
	rm -f "$root/etc/init.d/mt6895-firstboot"
	distro_enable_units "$root" mt6895-firstboot.service
	# Identity/accounts are configured here, not by an interactive boot prompt.
	systemctl --root="$root" mask systemd-firstboot.service
	rm -f "$root/etc/resolv.conf" "$root/etc/ssh/ssh_host_"* "$root/var/lib/dbus/machine-id"
	ln -s /run/NetworkManager/resolv.conf "$root/etc/resolv.conf"
	: > "$root/etc/machine-id"
	find "$root/var/cache" -type f -delete
	[ ! -d "$root/var/lib/apt/lists" ] || find "$root/var/lib/apt/lists" -type f -delete
}
