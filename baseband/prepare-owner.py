#!/usr/bin/env python3
"""Prepare only the reviewed qqcandy kernel integration; never starts MD."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

SUPPORT = Path('/var/lib/mtk-ccci/qqcandy-532')
PROFILE = Path('/etc/mtk-ccci/boot-profile.json')
PROTECTED = {'nvdata': 'nvdata', 'nvcfg': 'nvcfg', 'protect1': 'protect_f',
             'protect2': 'protect_s', 'mcf_ota_a': 'mcf_ota'}


def run(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def safe_path(root, relative):
    path = Path(relative)
    if path.is_absolute() or '..' in path.parts or not path.parts:
        raise ValueError('unsafe support path')
    result = root / path
    if result.resolve() != result.absolute():
        raise ValueError('symlink in support path')
    return result


def validate_support(profile, root, reviewed):
    if (profile.get('schema') != 1 or profile.get('integration') != 'qqcandy-532' or
            profile.get('support_root') != str(SUPPORT)):
        raise ValueError('unsupported boot profile')
    files = profile.get('immutable_files', {})
    if not isinstance(files, dict) or not files:
        raise ValueError('missing immutable support manifest')
    modules = {'modules/' + name: digest for name, digest in reviewed['modules'].items()}
    if {name: files.get(name) for name in modules} != modules:
        raise ValueError('modules differ from the reviewed integration')
    if not any(name.startswith('vendor/etc/md/') for name in files):
        raise ValueError('missing private modem vendor data')
    for name, digest in files.items():
        if name not in modules and not name.startswith('vendor/etc/md/'):
            raise ValueError('mutable or unsupported data in immutable manifest')
        path = safe_path(root, name)
        if not stat.S_ISREG(path.stat().st_mode):
            raise ValueError('support input is not a regular file')
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('immutable support hash mismatch: ' + name)
    # COW contents intentionally change. Never compare them with seed hashes.
    for name in ('private/overlay', 'private-data', 'evidence'):
        if not safe_path(root, name).is_dir():
            raise ValueError('missing private write directory: ' + name)


def validate_mount(info, target, device):
    mounts = info.get('filesystems', [])
    if len(mounts) != 1:
        raise ValueError('missing exact protected mount')
    mount = mounts[0]
    options = set(mount.get('options', '').split(','))
    if (mount.get('target') != str(target) or mount.get('fstype') != 'ext4' or
            'ro' not in options or not options.intersection({'noload', 'norecovery'}) or
            os.path.realpath(mount.get('source', '')) != str(device.resolve())):
        raise ValueError('protected mount is not the exact ro,noload ext4 device')


def ensure_mounts(prepare):
    for label, name in PROTECTED.items():
        device = Path('/dev/disk/by-partlabel') / label
        if not stat.S_ISBLK(device.stat().st_mode):
            raise ValueError('missing protected block device: ' + label)
        target = Path('/mnt/vendor') / name
        if target.resolve() != target:
            raise ValueError('protected target contains a symlink')
        result = subprocess.run(['findmnt', '--json', '--output', 'TARGET,SOURCE,FSTYPE,OPTIONS',
                                 '--mountpoint', str(target)], capture_output=True, text=True,
                                timeout=10)
        if result.returncode:
            if result.returncode != 1 or not prepare:
                raise ValueError('protected mount unavailable: ' + name)
            # Refuse an existing use elsewhere; never remount or replay a journal.
            used = subprocess.run(['findmnt', '--source', str(device.resolve())],
                                  capture_output=True, timeout=10)
            if used.returncode != 1:
                raise ValueError('protected device already mounted elsewhere')
            target.mkdir(parents=True, exist_ok=True)
            run('mount', '-t', 'ext4', '-o', 'ro,noload', str(device), str(target))
            result = subprocess.run(['findmnt', '--json', '--output', 'TARGET,SOURCE,FSTYPE,OPTIONS',
                                     '--mountpoint', str(target)], capture_output=True, text=True,
                                    check=True, timeout=10)
        validate_mount(json.loads(result.stdout), target, device)


def active_processes():
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            exe = Path(os.readlink(process / 'exe')).name
            comm = (process / 'comm').read_text().strip()
        except OSError:
            continue
        if exe in ('ModemManager', 'ccci_rpcd', 'emdlogger') or comm == 'ccci_mdinit':
            raise ValueError('modem process already active: ' + exe)


def state():
    return Path('/sys/kernel/ccci/boot').read_text().split('|', 1)[0].strip()


def prepare_modules(reviewed, prepare):
    loaded = {line.split()[0] for line in Path('/proc/modules').read_text().splitlines()}
    expected = {name.split('.')[0] for name in reviewed['modules']}
    present = {name for name in loaded if name.startswith('ccci_')}
    receipt = Path('/run/mtk-ccci/prepared.json')
    expected_receipt = {'boot': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                        'modules': reviewed['modules'], 'notes_sha256': reviewed['notes_sha256']}
    if present:
        if not receipt.is_file() or json.loads(receipt.read_text()) != expected_receipt:
            raise ValueError('loaded CCCI has no matching preparation receipt; not adopting it')
        if present != expected or state() != 'md1:0':
            raise ValueError('partial or active CCCI; no reload/unload permitted')
        if not Path('/sys/bus/platform/drivers/ccci_hif_dpmaif/10014000.dpmaif').is_symlink():
            raise ValueError('DPMAIF not bound')
        return
    if state() != 'md1:n/a':
        raise ValueError('unexpected pre-load MD state')
    if not prepare:
        print('Modules absent; prepare will load the pinned integration')
        return
    for name in ('auxadc', 'md_clk', 'rtc', 'md_all'):
        run('insmod', str(SUPPORT / 'modules' / ('ccci_' + name + '.ko')))
    power = Path('/sys/kernel/debug/pm_genpd/pm_genpd_summary').read_text()
    if not any(line.split()[:2] == ['md', 'on'] for line in power.splitlines()):
        raise ValueError('MD not on: stop before CCIF; do not unload')
    for name in ('fsm_scp', 'ccif'):
        run('insmod', str(SUPPORT / 'modules' / ('ccci_' + name + '.ko')))
    for clock in ('ifrao_dpmaif_main', 'ifrao_cldmabclk', 'ifrao_dpmaif_26m'):
        if not Path('/sys/kernel/debug/clk', clock).is_dir():
            raise ValueError('missing DPMAIF clock')
    run('insmod', str(SUPPORT / 'modules/ccci_dpmaif.v605.ko'))
    if state() != 'md1:0':
        raise ValueError('loaded MD not idle')
    if not Path('/sys/bus/platform/drivers/ccci_hif_dpmaif/10014000.dpmaif').is_symlink():
        raise ValueError('DPMAIF not bound')
    if b'hif register: 2' not in Path('/proc/ccci_dump').read_bytes():
        raise ValueError('DPMAIF HIF2 not registered')
    receipt.write_text(json.dumps(expected_receipt) + '\n')
    receipt.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true')
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise ValueError('root required')
        reviewed = json.loads(Path(__file__).with_name('qqcandy-532.json').read_text())
        if Path('/proc/sys/kernel/osrelease').read_text().strip() != reviewed['kernel']:
            raise ValueError('kernel release mismatch')
        if hashlib.sha256(Path('/sys/kernel/notes').read_bytes()).hexdigest() != reviewed['notes_sha256']:
            raise ValueError('kernel notes mismatch')
        if reviewed['compatible'].encode() not in Path('/proc/device-tree/compatible').read_bytes().split(b'\0'):
            raise ValueError('board mismatch')
        if not Path('/proc/device-tree/soc@0/dpmaif@10014000').is_dir():
            raise ValueError('not the reviewed normal-boot DT')
        validate_support(json.loads(PROFILE.read_text()), SUPPORT, reviewed)
        for name in reviewed['modules']:
            if run('modinfo', '-F', 'vermagic', str(SUPPORT / 'modules' / name)) != reviewed['vermagic']:
                raise ValueError('module vermagic mismatch')
        active_processes()
        override = Path('/usr/local/share/dbus-1/system-services/org.freedesktop.ModemManager1.service')
        if 'Exec=/bin/false' not in override.read_text().splitlines():
            raise ValueError('distribution MM activation not inhibited')
        # Serialize the preparation independently of the eventual owner lock.
        Path('/run/mtk-ccci').mkdir(mode=0o700, exist_ok=True)
        with Path('/run/mtk-ccci/prepare.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            active_processes()
            ensure_mounts(args.prepare)
            prepare_modules(reviewed, args.prepare)
        print('Reviewed CCCI preparation passed; modem owner not started')
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('CCCI preparation refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
