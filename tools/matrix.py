#!/usr/bin/env python3
"""Validate workflow inputs and generate a structured device/distro matrix."""
import json
import sys

DEVICES = {
    "qqcandy": ("qqcandy", ""),
    "pearl": ("pearl", ""),
    "xaga": ("xaga", ""),
    "xaga-6.18": ("xaga", "-6.18"),
    "rubens": ("rubens", ""),
}
DISTROS = {"debian", "mobian", "arch", "nura"}


def matrix(devices, distros):
    devices, distros = devices.split(), distros.split()
    if not devices or not distros:
        raise ValueError("Select at least one device and distribution")
    if len(set(devices)) != len(devices) or len(set(distros)) != len(distros):
        raise ValueError("Duplicate device/distribution")
    if not set(devices) <= DEVICES.keys() or not set(distros) <= DISTROS:
        raise ValueError("Unknown device/distribution")
    return {"include": [
        {"variant": variant, "device": DEVICES[variant][0],
         "suffix": DEVICES[variant][1], "distro": distro}
        for variant in devices for distro in distros
    ]}


if __name__ == "__main__":
    try:
        print("matrix=" + json.dumps(matrix(*sys.argv[1:]), separators=(",", ":")))
    except (TypeError, ValueError) as error:
        raise SystemExit(str(error))
