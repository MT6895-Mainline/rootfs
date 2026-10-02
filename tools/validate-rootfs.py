#!/usr/bin/env python3
"""Check offline image contracts without booting or changing target hardware."""
import argparse
import os
from pathlib import Path
import struct


def rooted(root, name):
    """Resolve absolute target symlinks inside the image, never on the host."""
    pending = list(Path(name).parts)
    parts = []
    links = 0
    while pending:
        item = pending.pop(0)
        if item in ("/", "."):
            continue
        if item == "..":
            if not parts:
                raise ValueError("path escapes rootfs")
            parts.pop()
            continue
        path = root.joinpath(*parts, item)
        if path.is_symlink():
            links += 1
            if links > 40:
                raise ValueError("symlink loop")
            target = os.readlink(path)
            if target.startswith("/"):
                parts = []
            pending = list(Path(target).parts) + pending
        else:
            parts.append(item)
    return root.joinpath(*parts)


def aarch64(path):
    with path.open("rb") as source:
        header = source.read(20)
    if len(header) != 20 or header[:6] != b"\x7fELF\x02\x01":
        raise ValueError(f"not a little-endian ELF64: {path}")
    if struct.unpack_from("<H", header, 18)[0] != 183:
        raise ValueError(f"not AArch64: {path}")


def enabled(root, unit):
    directory = root / "etc/systemd/system"
    return any(path.is_symlink() for path in directory.glob(f"*.wants/{unit}"))


def validate(args):
    root = args.root.resolve()
    aarch64(rooted(root, "/sbin/init"))
    passwd = dict((line.split(":")[0], line.split(":"))
                  for line in (root / "etc/passwd").read_text().splitlines())
    user = passwd[args.user]
    if user[2] == "0" or user[6] != "/bin/bash":
        raise ValueError("normal user must be non-root with bash")
    shadow = dict(line.split(":", 2)[:2]
                  for line in (root / "etc/shadow").read_text().splitlines())
    if not args.allow_root_password and not shadow["root"].startswith(("!", "*")):
        raise ValueError("root password is not locked")
    ssh = (root / "etc/ssh/sshd_config.d/10-mt6895.conf").read_text()
    if "PermitRootLogin no" not in ssh or "PasswordAuthentication no" not in ssh:
        raise ValueError("SSH password/root login must be disabled")
    if any((root / "etc/ssh").glob("ssh_host_*_key")):
        raise ValueError("image contains installation-specific SSH keys")
    if os.readlink(root / "etc/resolv.conf") != "/run/NetworkManager/resolv.conf":
        raise ValueError("wrong runtime DNS provider")
    if (root / "etc/machine-id").read_text().strip():
        raise ValueError("image has a pre-generated machine identity")
    if (root / "var/lib/mt6895-firstboot-done").exists():
        raise ValueError("firstboot was already marked done")
    if not (root / "usr/local/sbin/mt6895-firstboot").stat().st_mode & 0o111:
        raise ValueError("firstboot script is not executable")
    if args.init == "systemd":
        units = ["NetworkManager.service", "bluetooth.service", "ModemManager.service",
                 args.ssh_unit, "mt6895-firstboot.service"]
        if args.ui == "phosh":
            units.append(args.phosh_unit)
            if os.readlink(root / "etc/systemd/system/default.target").split("/")[-1] != "graphical.target":
                raise ValueError("Phosh must boot to graphical.target")
            if args.phosh_unit != "phosh.service" and enabled(root, "phosh.service"):
                raise ValueError("greeter and development Phosh service both enabled")
        for unit in units:
            if not enabled(root, unit):
                raise ValueError(f"unit not enabled: {unit}")
    else:
        services = ["networkmanager", "bluetooth", "modemmanager", "sshd", "mt6895-firstboot"]
        if args.ui == "phosh":
            services.append("greetd")
        for service in services:
            if not (root / "etc/runlevels/default" / service).is_symlink():
                raise ValueError(f"OpenRC service not enabled: {service}")
    if args.ui == "phosh":
        if not rooted(root, "/usr/bin/phosh-session").is_file():
            raise ValueError("missing Phosh session")
    if args.device == "qqcandy":
        ucm = root / "usr/share/alsa/ucm2/MediaTek/qqcandy/HiFi.conf"
        if not ucm.is_file():
            raise ValueError("missing qqcandy UCM")
    if args.vaapi:
        drivers = list((root / "usr/lib").rglob("mtk_vcp_drv_video.so"))
        if len(drivers) != 1:
            raise ValueError("expected exactly one VA-API driver")
        aarch64(drivers[0])
    if args.kernel != "none":
        modules = rooted(root, "/lib/modules")
        if sorted(path.name for path in modules.iterdir()) != [args.kernel]:
            raise ValueError("kernel/module directory mismatch")
        if not (modules / args.kernel / "modules.dep").is_file():
            raise ValueError("missing modules.dep")
    print(f"Rootfs contracts passed: {args.device}, {args.init}, {args.ui}, kernel={args.kernel}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--user", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--init", choices=("systemd", "openrc"), required=True)
    parser.add_argument("--ui", choices=("phosh", "console"), required=True)
    parser.add_argument("--ssh-unit", default="ssh.service")
    parser.add_argument("--phosh-unit", default="greetd.service")
    parser.add_argument("--kernel", default="none")
    parser.add_argument("--vaapi", action="store_true")
    parser.add_argument("--allow-root-password", action="store_true")
    args = parser.parse_args()
    try:
        validate(args)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Rootfs validation failed: {error}\n")


if __name__ == "__main__":
    main()
