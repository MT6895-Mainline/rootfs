#!/usr/bin/env python3
"""Bounded read-only READY gate; never starts or resets the modem."""
import argparse
from pathlib import Path
import sys
import time


def wait_ready(path, timeout):
    deadline = time.monotonic() + timeout
    while True:
        state = path.read_text().split("|", 1)[0].strip()
        if state == "md1:4":
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(f"modem did not reach READY: {state}")
        time.sleep(min(0.5, max(0, deadline - time.monotonic())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    if not 0 < args.timeout <= 300:
        parser.error("timeout must be greater than zero and no more than 300 seconds")
    try:
        wait_ready(Path("/sys/kernel/ccci/boot"), args.timeout)
    except (OSError, RuntimeError) as error:
        print(f"CCCI READY gate refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
