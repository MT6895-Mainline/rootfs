#!/usr/bin/env python3
"""Import an external ARM64 module set; never compile or load a module."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import lzma
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess

spec = importlib.util.spec_from_file_location("rootfs_validator", Path(__file__).with_name("validate-rootfs.py"))
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def module_header(path):
    if path.name.endswith(".gz"):
        with gzip.open(path, "rb") as stream:
            return stream.read(20)
    if path.name.endswith(".xz"):
        with lzma.open(path, "rb") as stream:
            return stream.read(20)
    if path.name.endswith(".zst"):
        return subprocess.check_output(["zstd", "-qdc", str(path)])[:20]
    with path.open("rb") as stream:
        return stream.read(20)


def inspect(source, release):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", release) or release == "none":
        raise ValueError("unsafe or empty kernel release")
    if source.is_symlink() or not source.is_dir() or source.name != release:
        raise ValueError("source must be a real single <kernel-release> directory")
    files = {}
    modules = []
    vermagic = None
    for directory, directories, names in os.walk(source, followlinks=False):
        for name in sorted(directories + names):
            path = Path(directory) / name
            relative = path.relative_to(source)
            if relative.as_posix() in ("build", "source"):
                if name in directories:
                    directories.remove(name)
                continue
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                continue
            if not stat.S_ISREG(mode):
                raise ValueError(f"symlink or special file in modules: {relative}")
            files[relative.as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
            if not path.name.endswith((".ko", ".ko.gz", ".ko.xz", ".ko.zst")):
                continue
            header = module_header(path)
            if (len(header) != 20 or header[:6] != b"\x7fELF\x02\x01" or
                    struct.unpack_from("<H", header, 16)[0] != 1 or
                    struct.unpack_from("<H", header, 18)[0] != 183):
                raise ValueError(f"not an ARM64 relocatable module: {relative}")
            value = subprocess.check_output(["modinfo", "-F", "vermagic", str(path)], text=True).strip()
            if not value or value.split()[0] != release:
                raise ValueError(f"module release mismatch: {relative}: {value}")
            if vermagic is not None and value != vermagic:
                raise ValueError(f"mixed module vermagic: {relative}")
            vermagic = value
            modules.append(relative.as_posix())
    if not modules:
        raise ValueError("module source contains no .ko modules")
    return {"schema": 1, "release": release, "vermagic": vermagic,
            "modules": sorted(modules), "source_files_sha256": dict(sorted(files.items())),
            "boot_built": False, "hardware_validated": False, "symbol_versions_validated": False}


def install(root, source, release):
    root = root.resolve(strict=True)
    if root == Path("/"):
        raise ValueError("offline rootfs only; refusing the live host")
    record = inspect(source, release)
    base = validator.rooted(root, "/lib/modules")
    if base.exists() and any(base.iterdir()):
        raise ValueError("refusing to mix or replace existing module sets")
    destination = base / release
    destination.mkdir(parents=True)
    for name, digest in record["source_files_sha256"].items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise ValueError(f"module source changed during import: {name}")
    subprocess.run(["depmod", "-b", str(root), release], check=True)
    if not (destination / "modules.dep").is_file():
        raise ValueError("depmod did not create modules.dep")
    manifest = validator.rooted(root, "/usr/share/mt6895-build/kernel-modules.json")
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(record, indent=2) + "\n")
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--release", required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check-only", action="store_true")
    mode.add_argument("--root", type=Path)
    args = parser.parse_args()
    try:
        record = inspect(args.source, args.release) if args.check_only else install(args.root, args.source, args.release)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Module import failed: {error}\n")
    print(f"External modules checked: {record['release']}, {len(record['modules'])} modules; boot not validated")


if __name__ == "__main__":
    main()
