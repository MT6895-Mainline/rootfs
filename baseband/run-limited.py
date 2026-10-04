#!/usr/bin/env python3
"""Apply a hard lifetime to the existing owner/MM services without respawning."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

RUNTIME = Path('/run/mtk-ccci')
MAX_RUNTIME = 86400
MM_STOP_MARGIN = 30


def start_ticks(pid):
    return Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[19]


def remaining(info, boot, now):
    if info.get('boot') != boot or info.get('start_ticks') != start_ticks(info['pid']):
        raise ValueError('owner lifetime record does not match a live process')
    duration = int(info['deadline'] - now - MM_STOP_MARGIN)
    if not 0 < duration <= MAX_RUNTIME - MM_STOP_MARGIN:
        raise ValueError('owner lifetime has expired or is invalid')
    return duration


def run_child(timeout, duration, grace, command):
    # Keep this Python PID stable for OpenRC's pidfile, even when timeout execs.
    stopping = []
    child = None

    def forward(signum, frame):
        if not stopping:
            stopping.append(time.monotonic() + grace + 5)
        if child is not None and child.poll() is None:
            child.send_signal(signum)

    previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        child = subprocess.Popen([timeout, '-s', 'TERM', '-k', str(grace), str(duration), *command])
        if stopping:
            child.terminate()
        while True:
            try:
                result = child.wait(timeout=0.5)
                return result if result >= 0 else 128 - result
            except subprocess.TimeoutExpired:
                if stopping and time.monotonic() >= stopping[0]:
                    child.kill()
                    return child.wait(timeout=5)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--role', choices=('owner', 'modemmanager'), required=True)
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise ValueError('root required')
        timeout = shutil.which('timeout')
        if not timeout:
            raise ValueError('timeout utility missing')
        boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        RUNTIME.mkdir(mode=0o700, exist_ok=True)
        lock = (RUNTIME / (args.role + '-lifetime.lock')).open('a')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        record = RUNTIME / 'owner-deadline.json'
        if args.role == 'owner':
            duration = MAX_RUNTIME
            info = {'boot': boot, 'pid': os.getpid(), 'start_ticks': start_ticks(os.getpid()),
                    'deadline': time.monotonic() + duration}
            temporary = record.with_suffix('.new')
            temporary.write_text(json.dumps(info) + '\n')
            temporary.chmod(0o600)
            temporary.replace(record)
            command = '/usr/libexec/mtk-ccci/start-owner'
        else:
            duration = remaining(json.loads(record.read_text()), boot, time.monotonic())
            command = '/usr/libexec/mtk-ccci/ModemManager'
        grace = 30 if args.role == 'owner' else 10
        return run_child(timeout, duration, grace, [command])
    except (OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
        print('CCCI bounded service refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
