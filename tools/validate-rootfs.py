#!/usr/bin/env python3
"""Check offline image contracts without booting or changing target hardware."""
import argparse
import configparser
import json
import os
from pathlib import Path
import re
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
    paths = list(directory.glob(f"*.wants/{unit}"))
    if unit in ("gdm.service", "greetd.service"):
        paths.append(directory / "display-manager.service")
    return any(path.is_symlink() and rooted(root, path.relative_to(root)).is_file()
               and rooted(root, path.relative_to(root)).name == unit for path in paths)


def validate_gdm(root, user):
    if not (root / "usr/share/wayland-sessions/phosh.desktop").is_file():
        raise ValueError("missing GDM Phosh Wayland session")
    config = configparser.ConfigParser()
    config.read(root / "var/lib/AccountsService/users" / user)
    if (config.get("User", "Session", fallback="") != "phosh" or
            config.get("User", "SessionType", fallback="") != "wayland"):
        raise ValueError("GDM default user session is not Phosh/Wayland")


def require_modules(directory, names):
    for name in names:
        if not any(path.is_file() for extension in (".ko", ".ko.xz", ".ko.zst", ".ko.gz")
                   for path in directory.rglob(name + extension)):
            raise ValueError(f"missing required kernel module: {name}")


def validate_baseband(root, bundle_path=None):
    manifest_path = (rooted(root, bundle_path) / "manifest.json" if bundle_path else
                     root / "usr/share/mt6895-build/baseband.json")
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get("schema") != 1 or manifest.get("device") != "qqcandy" or
            manifest.get("distro") not in ("mobian", "debian", "arch", "nura") or
            manifest.get("autostart") is not False or manifest.get("hardware_validated") is not False):
        raise ValueError("invalid baseband installation or hardware claims")
    commits = [manifest.get(name, "") for name in ("owner_commit", "mm_commit")]
    if not all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) for value in commits):
        raise ValueError("baseband sources are not immutable commits")
    release = "-".join(commits)
    base = root / "usr/lib/mtk-ccci"
    if not bundle_path and os.readlink(base / "current") != "releases/" + release:
        raise ValueError("baseband manifest/current release mismatch")
    bundle = rooted(root, bundle_path or "/usr/lib/mtk-ccci/current")
    if bundle != base / "releases" / release:
        raise ValueError("baseband release path differs from its source commits")
    if json.loads((bundle / "manifest.json").read_text()) != manifest:
        raise ValueError("baseband bundle manifest mismatch")
    for name in ("mm/sbin/ModemManager", "mm/lib/ModemManager/libmm-plugin-mtk-soc.so"):
        aarch64(bundle / name)
    for name in ("owner/libexec/mtk-ccci/start_owner.py", "owner/libexec/mtk-ccci/mdinit.py"):
        if not (bundle / name).is_file():
            raise ValueError(f"missing baseband owner: {name}")
    if not rooted(root, str((bundle / "mm/lib/libmm-glib.so.0").relative_to(root))).is_file():
        raise ValueError("missing private MM library")
    for name in ("ModemManager", "start-owner", "wait-ready.py"):
        if not (root / "usr/libexec/mtk-ccci" / name).stat().st_mode & 0o111:
            raise ValueError(f"baseband entrypoint is not executable: {name}")
    if not (root / "etc/udev/rules.d/77-mm-mtk-soc.rules").is_file():
        raise ValueError("missing MTK modem udev rule")
    for service in ("mtk-ccci-owner", "mtk-modemmanager"):
        if manifest["distro"] == "nura":
            unit = root / "etc/init.d" / service
            if not unit.is_file() or not unit.stat().st_mode & 0o111:
                raise ValueError(f"missing executable OpenRC baseband service: {service}")
        elif not (root / "usr/lib/systemd/system" / (service + ".service")).is_file():
            raise ValueError(f"missing systemd baseband service: {service}")
    for unit in ("mtk-ccci-owner.service", "mtk-modemmanager.service"):
        if enabled(root, unit) or any((root / "etc/systemd/system").glob(f"*.requires/{unit}")):
            raise ValueError("unvalidated baseband service automatically enabled")
    for service in ("mtk-ccci-owner", "mtk-modemmanager"):
        if any((root / "etc/runlevels").glob(f"*/{service}")):
            raise ValueError("unvalidated OpenRC baseband service automatically enabled")
    print(f"Baseband installation contracts passed: {release}; hardware startup not validated")


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
        if (root / "etc/init.d/mt6895-firstboot").exists():
            raise ValueError("OpenRC firstboot script in a systemd image")
        units = ["NetworkManager.service", "bluetooth.service", "ModemManager.service",
                 args.ssh_unit, "mt6895-firstboot.service"]
        if args.ui == "phosh":
            units.append(args.phosh_unit)
            if os.readlink(root / "etc/systemd/system/default.target").split("/")[-1] != "graphical.target":
                raise ValueError("Phosh must boot to graphical.target")
            if args.phosh_unit != "phosh.service" and enabled(root, "phosh.service"):
                raise ValueError("greeter and development Phosh service both enabled")
            if args.phosh_unit == "gdm.service":
                validate_gdm(root, args.user)
        for unit in units:
            if not enabled(root, unit):
                raise ValueError(f"unit not enabled: {unit}")
    else:
        if (root / "etc/systemd/system/mt6895-firstboot.service").exists():
            raise ValueError("systemd firstboot unit in an OpenRC image")
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
    if args.baseband:
        validate_baseband(root)
    if args.kernel != "none":
        modules = rooted(root, "/lib/modules")
        if sorted(path.name for path in modules.iterdir()) != [args.kernel]:
            raise ValueError("kernel/module directory mismatch")
        if not (modules / args.kernel / "modules.dep").is_file():
            raise ValueError("missing modules.dep")
        require_modules(modules / args.kernel, args.required_module)
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
    parser.add_argument("--required-module", action="append", default=[])
    parser.add_argument("--vaapi", action="store_true")
    parser.add_argument("--baseband", action="store_true")
    parser.add_argument("--allow-root-password", action="store_true")
    args = parser.parse_args()
    try:
        validate(args)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Rootfs validation failed: {error}\n")


if __name__ == "__main__":
    main()
