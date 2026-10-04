#!/usr/bin/env python3
"""Check offline image contracts without booting or changing target hardware."""
import argparse
import configparser
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import struct
import tomllib


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


def validate_identity(root, init):
    machine_id = root / "etc/machine-id"
    dbus_id = root / "var/lib/dbus/machine-id"
    if dbus_id.exists() or dbus_id.is_symlink():
        raise ValueError("image contains a D-Bus machine identity")
    if init == "openrc":
        if machine_id.exists() or machine_id.is_symlink():
            raise ValueError("OpenRC image must omit machine-id, not leave an empty file")
    elif machine_id.is_symlink() or machine_id.read_bytes() != b"":
        raise ValueError("systemd image must have an empty machine-id")


def validate_phosh_schemas(root, schemas):
    if schemas is None:
        raise ValueError("Phosh validation needs target gsettings list-schemas output")
    available = set(schemas.read_text().splitlines())
    required = {"sm.puri.phosh"}
    if rooted(root, "/usr/bin/phosh-osk-stevia").is_file():
        required.add("mobi.phosh.osk")
    missing = required - available
    if missing:
        raise ValueError("missing compiled runtime schemas: " + ", ".join(sorted(missing)))


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
    for name in ("ModemManager", "start-owner", "wait-ready.py", "prepare-owner.py", "run-limited.py"):
        if not (root / "usr/libexec/mtk-ccci" / name).stat().st_mode & 0o111:
            raise ValueError(f"baseband entrypoint is not executable: {name}")
    if not (root / "etc/udev/rules.d/77-mm-mtk-soc.rules").is_file():
        raise ValueError("missing MTK modem udev rule")
    for service in ("mtk-ccci-prepare", "mtk-ccci-owner", "mtk-modemmanager"):
        if manifest["distro"] == "nura":
            unit = root / "etc/init.d" / service
            if not unit.is_file() or not unit.stat().st_mode & 0o111:
                raise ValueError(f"missing executable OpenRC baseband service: {service}")
        elif not (root / "usr/lib/systemd/system" / (service + ".service")).is_file():
            raise ValueError(f"missing systemd baseband service: {service}")
    boot_config = root / 'usr/share/mt6895-build/baseband-boot.json'
    guarded_boot = boot_config.is_file()
    if guarded_boot:
        validate_baseband_boot(root, manifest['distro'])
    for unit in ("mtk-ccci-owner.service", "mtk-modemmanager.service", "mtk-ccci-prepare.service"):
        if guarded_boot:
            continue
        if enabled(root, unit) or any((root / "etc/systemd/system").glob(f"*.requires/{unit}")):
            raise ValueError("unvalidated baseband service automatically enabled")
    for service in ("mtk-ccci-owner", "mtk-modemmanager"):
        if guarded_boot:
            continue
        if any((root / "etc/runlevels").glob(f"*/{service}")):
            raise ValueError("unvalidated OpenRC baseband service automatically enabled")
    print(f"Baseband installation contracts passed: {release}; hardware startup not validated")
    return guarded_boot


def validate_baseband_boot(root, distro):
    here = Path(__file__).resolve().parents[1]
    marker = json.loads((root / 'usr/share/mt6895-build/baseband-boot.json').read_text())
    if marker != {'schema': 1, 'integration': 'qqcandy-532', 'autostart': True,
                  'hardware_validated': False, 'private_support': True}:
        raise ValueError('invalid guarded boot provisioning claims')
    spec = importlib.util.spec_from_file_location('prepare_contract', here / 'baseband/prepare-owner.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    reviewed = json.loads((here / 'baseband/qqcandy-532.json').read_text())
    profile = json.loads((root / 'etc/mtk-ccci/boot-profile.json').read_text())
    module.validate_support(profile, root / str(module.SUPPORT).lstrip('/'), reviewed)
    spec = importlib.util.spec_from_file_location('provision_contract', here / 'tools/provision-baseband.py')
    provision = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(provision)
    assignments = shlex.split((root / 'etc/default/mtk-ccci').read_text(), comments=True)
    if any('=' not in word for word in assignments):
        raise ValueError('invalid owner environment')
    environment = dict(word.split('=', 1) for word in assignments)
    if len(environment) != len(assignments) or environment != provision.owner_environment(reviewed):
        raise ValueError('owner environment differs from boot profile')
    for name in ('prepare-owner.py', 'run-limited.py', 'qqcandy-532.json'):
        if (root / 'usr/libexec/mtk-ccci' / name).read_bytes() != (here / 'baseband' / name).read_bytes():
            raise ValueError('guarded boot integration differs from reviewed source')
    override = root / 'usr/local/share/dbus-1/system-services/org.freedesktop.ModemManager1.service'
    if 'Exec=/bin/false' not in override.read_text().splitlines():
        raise ValueError('distribution MM activation not inhibited')
    for service in ('mtk-ccci-prepare', 'mtk-ccci-owner', 'mtk-modemmanager'):
        installed = (root / 'etc/init.d' / service if distro == 'nura' else
                     root / 'usr/lib/systemd/system' / (service + '.service'))
        source = here / 'baseband' / (service + ('.initd' if distro == 'nura' else '.service'))
        if installed.read_bytes() != source.read_bytes():
            raise ValueError('unreviewed baseband boot service')
    if distro == 'nura':
        if any((root / 'etc/runlevels').glob('*/modemmanager')):
            raise ValueError('distribution MM still automatically enabled')
        for service in ('mtk-ccci-owner', 'mtk-modemmanager'):
            link = root / 'etc/runlevels/default' / service
            if not link.is_symlink() or os.readlink(link) != '/etc/init.d/' + service:
                raise ValueError('guarded baseband OpenRC service not enabled')
    else:
        mask = root / 'etc/systemd/system/ModemManager.service'
        if not mask.is_symlink() or os.readlink(mask) != '/dev/null':
            raise ValueError('distribution MM not masked')
        for service in ('mtk-ccci-owner', 'mtk-modemmanager'):
            if not enabled(root, service + '.service'):
                raise ValueError('guarded baseband unit not enabled')


def validate_cutout(root):
    here = Path(__file__).resolve().parents[1]
    native = here / 'ui/phosh/qqcandy-native'
    marker = json.loads((root / 'usr/share/mt6895-build/phosh-cutout.json').read_text())
    expected = {'schema': 1, 'device': 'qqcandy', 'distro': 'nura',
                'phosh_version': '0.57.0', 'phrog_version': '0.53.0',
                'hardware_validated': False,
                'patch_sha256': hashlib.sha256(
                    (here / 'ui/phosh/patches/0001-top-bar-cutout-height.patch').read_bytes()).hexdigest()}
    if marker != expected:
        raise ValueError('unreviewed native cutout build')
    for name in ('usr/libexec/phosh', 'usr/bin/phrog', 'usr/lib/libphosh-0.45.so.0',
                 'usr/lib/qqcandy-phosh/phosh', 'usr/lib/qqcandy-phosh/libphosh-0.45.so.0'):
        aarch64(rooted(root, name))
    for name in ('shell', 'greeter'):
        installed = rooted(root, 'usr/libexec/qqcandy-phosh/' + name)
        if installed.read_bytes() != (native / name).read_bytes() or not installed.stat().st_mode & 0o111:
            raise ValueError('missing or modified native cutout wrapper')
    panel = rooted(root, 'usr/share/qqcandy-phosh/panels/oplus,qqcandy.json')
    if panel.read_bytes() != (native / 'panels/oplus,qqcandy.json').read_bytes():
        raise ValueError('unreviewed cutout panel')
    config = rooted(root, 'etc/phrog/greetd-config.toml')
    if tomllib.loads(config.read_text()) != tomllib.loads((native / 'greetd-config.toml').read_text()):
        raise ValueError('native cutout greeter not activated')
    original = rooted(root, 'usr/share/qqcandy-phosh/original-greetd-config.toml')
    if tomllib.loads(original.read_text()) != {'terminal': {'vt': 7}, 'default_session': {
            'command': '/usr/libexec/phrog-greetd-session', 'user': 'greetd'}}:
        raise ValueError('missing original greeter configuration')
    stock = rooted(root, 'usr/share/applications/mobi.phosh.Shell.desktop').read_text()
    expected_desktop = re.sub(r'^Exec=.*$', 'Exec=/usr/libexec/qqcandy-phosh/shell', stock, flags=re.M)
    if expected_desktop == stock or rooted(root, 'usr/local/share/applications/mobi.phosh.Shell.desktop').read_text() != expected_desktop:
        raise ValueError('native cutout desktop not activated')
    print('Native cutout image contracts passed; whole-image hardware acceptance not claimed')


def validate(args):
    root = args.root.resolve()
    aarch64(rooted(root, "/sbin/init"))
    if args.phosh_cutout or (root / 'usr/share/mt6895-build/phosh-cutout.json').is_file():
        if args.device != 'qqcandy' or args.init != 'openrc' or args.ui != 'phosh':
            raise ValueError('native cutout installed on an unreviewed profile')
        validate_cutout(root)
    guarded_boot = validate_baseband(root) if args.baseband else False
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
    validate_identity(root, args.init)
    if (root / "var/lib/mt6895-firstboot-done").exists():
        raise ValueError("firstboot was already marked done")
    if not (root / "usr/local/sbin/mt6895-firstboot").stat().st_mode & 0o111:
        raise ValueError("firstboot script is not executable")
    if args.init == "systemd":
        if (root / "etc/init.d/mt6895-firstboot").exists():
            raise ValueError("OpenRC firstboot script in a systemd image")
        units = ["NetworkManager.service", "bluetooth.service",
                 args.ssh_unit, "mt6895-firstboot.service"]
        units.append('mtk-modemmanager.service' if guarded_boot else 'ModemManager.service')
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
        services = ["networkmanager", "bluetooth", "sshd", "mt6895-firstboot"]
        services.append('mtk-modemmanager' if guarded_boot else 'modemmanager')
        if args.ui == "phosh":
            services.append("greetd")
        for service in services:
            if not (root / "etc/runlevels/default" / service).is_symlink():
                raise ValueError(f"OpenRC service not enabled: {service}")
    if args.ui == "phosh":
        if not rooted(root, "/usr/bin/phosh-session").is_file():
            raise ValueError("missing Phosh session")
        validate_phosh_schemas(root, args.gsettings_schemas)
    if args.device == "qqcandy":
        ucm = root / "usr/share/alsa/ucm2/MediaTek/qqcandy/HiFi.conf"
        if not ucm.is_file():
            raise ValueError("missing qqcandy UCM")
    if args.vaapi:
        drivers = list((root / "usr/lib").rglob("mtk_vcp_drv_video.so"))
        if len(drivers) != 1:
            raise ValueError("expected exactly one VA-API driver")
        aarch64(drivers[0])
    modules = rooted(root, "/lib/modules")
    if args.kernel == "none":
        if modules.exists() and any(modules.iterdir()):
            raise ValueError("unexpected kernel modules without an external import")
    else:
        if sorted(path.name for path in modules.iterdir()) != [args.kernel]:
            raise ValueError("kernel/module directory mismatch")
        if not (modules / args.kernel / "modules.dep").is_file():
            raise ValueError("missing modules.dep")
        require_modules(modules / args.kernel, args.required_module)
        manifest = json.loads(rooted(root, "/usr/share/mt6895-build/kernel-modules.json").read_text())
        if manifest.get("release") != args.kernel or manifest.get("hardware_validated") is not False:
            raise ValueError("invalid external module manifest")
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
    parser.add_argument("--gsettings-schemas", type=Path)
    parser.add_argument("--kernel", default="none")
    parser.add_argument("--required-module", action="append", default=[])
    parser.add_argument("--vaapi", action="store_true")
    parser.add_argument("--baseband", action="store_true")
    parser.add_argument("--phosh-cutout", action="store_true")
    parser.add_argument("--allow-root-password", action="store_true")
    args = parser.parse_args()
    try:
        validate(args)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Rootfs validation failed: {error}\n")


if __name__ == "__main__":
    main()
