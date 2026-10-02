#!/usr/bin/env python3
"""Unmount only mounts beneath this build's pmbootstrap work directory."""
import json
import pathlib
import subprocess
import sys


def targets(data, root):
    prefix = str(root).rstrip("/") + "/"
    return sorted(
        [item["target"] for item in data["filesystems"]
         if item["target"].startswith(prefix)],
        key=lambda path: path.count("/"), reverse=True)


def main():
    root = pathlib.Path(sys.argv[1]).resolve(strict=True)
    if root.name != "pmb-work" or not root.parent.name.startswith(".work-"):
        raise SystemExit("Refusing to unmount outside a builder-owned pmb-work")
    result = subprocess.run(["findmnt", "--json", "--list", "--output", "TARGET"],
                            capture_output=True, text=True, check=True)
    for target in targets(json.loads(result.stdout), root):
        subprocess.run(["umount", "--", target], check=True)


if __name__ == "__main__":
    main()
