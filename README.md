# MT6895-Mainline rootfs

Flashable rootfs images for the MT6895 devices supported by
[MT6895-Mainline/linux](https://github.com/MT6895-Mainline/linux).

This repository is the rootfs half of the platform: it builds userspace images
and the kernel modules that must match the kernel you flash.  The kernel,
initramfs and boot-image side stays in the kernel repository.

**Landing now: `pearl` and `xaga`.**  `xaga-6.18`, `qqcandy` and `rubens` are
already wired up in `devices/` and can be enabled with the `devices` input.

| device | profile | kernel branch | kernel | config | rootfs label |
|---|---|---|---|---|---|
| `pearl` (Redmi Note 12T Pro) | `devices/pearl.conf` | `7.2-mt6895-xiaomi-pearl` | 7.2.7 | `pearl.config` | `archpearl` |
| `xaga` | `devices/xaga.conf` | `7.2-mt6895-xiaomi-xaga` | 7.2.0 | `xaga.config` | `xaga-rootfs` |
| `xaga-6.18` | `devices/xaga.conf` | `6.18-mt6895-xiaomi-xaga` | 6.18.0 | `xaga.config` | `xaga-rootfs` |
| `qqcandy` (OPPO K10 / Ace Racing) | `devices/qqcandy.conf` | `6.18-mt6895-oplus-qqcandy` | 6.18.0 | `qqcandy.config` | `mt6895qqcandy` |
| `rubens` (port) | `devices/rubens.conf` | `port/rubens-clean` | 7.2.0 | `rubens.config` | `mt6895rubens` |

## Quick start

Actions -> **rootfs** -> *Run workflow* (defaults: `devices = pearl xaga`,
Debian trixie).  When it finishes, every image is attached to a permanent
release tagged **`build-<UTC timestamp>`**, together with `SHA256SUMS` and
per-device build info.  Pushing such a tag yourself triggers the same run.

Local build (as root; needs `mmdebstrap`, `qemu-user-static`, `e2fsprogs`,
`android-sdk-libsparse-utils`, `pigz`, `kmod`):

```sh
git clone https://github.com/MT6895-Mainline/rootfs
git clone -b 7.2-mt6895-xiaomi-pearl https://github.com/MT6895-Mainline/linux
cd rootfs
sudo ./build.sh --device pearl --kernel-repo ../linux
```

## What you get

```
out/rootfs-<device>[-<tag>]-<YYYYmmdd-HHMMSS>-sparse.img.gz         # sparse ext4
out/rootfs-<device>[-<tag>]-<YYYYmmdd-HHMMSS>-sparse.img.gz.part-00 # when >2GB
out/SHA256SUMS   out/BUILD-INFO-<device>.txt
```

The root filesystem lives in the **userdata** partition (ext4, labelled as in
the table above; verified on pearl: partlabel `userdata` = `/dev/sdc86`, label
`archpearl`).  The neighbouring `nvdata` partition is `/dev/sdc13` on this SoC
family, which is what the initramfs needs for the WiFi/BT NVRAM.

```sh
gunzip -c rootfs-pearl-<ts>-sparse.img.gz | fastboot flash userdata -
fastboot reboot
```

On first boot `mt6895-firstboot.service` grows the filesystem to fill the
partition and regenerates the machine-id and SSH host keys.

The **boot image** is not built here: it belongs to the kernel repository
(kernel + initramfs + embedded DTB, MTK v4 header).  Build/flash `boot`
separately.

## Firmware (bring your own blobs)

Vendor firmware is proprietary and is **never** part of this branch or of its
images:

```sh
# on a device that already boots mainline Linux
sudo ./tools/extract-firmware.sh --from-rootfs /tmp/firmware.tar.zst
# or from the vendor partitions, for a first bring-up
sudo ./tools/extract-firmware.sh --from-partitions /tmp/vendor-firmware.tar.zst
```

Pass the contents with `build.sh --firmware DIR` or the workflow's
`firmware_url` input.  Without it the image boots but has no WiFi/BT/GPU
firmware.

## Layout

```
build.sh                 builder (kernel modules + mmdebstrap + overlay + image)
distros/debian.sh        distro backend (mmdebstrap; add one file per distro)
devices/<device>.conf    branch, config, DTS, labels, partitions, packages
overlay/common/          first-boot service, sysctl, shared files
overlay/<device>/        optional per-device quirks
tools/extract-firmware.sh, install-firmware.sh
```

## Design notes

* **Modules are built here, not downloaded.**  The kernel branch is checked out,
  configured exactly as the kernel is configured
  (`defconfig` + `arch/arm64/configs/<device>.config` + `olddefconfig`, with
  `KERNEL_MAKE_ARGS` matching the toolchain the boot image was built with) and
  `modules_install` goes straight into the rootfs, so `vermagic` cannot drift.
* `pearl` uses `KERNEL_MAKE_ARGS="LLVM=1"` because the pearl boot images in use
  are clang builds.
* Images are sparse (`img2simg`) and gzipped, split into 1900 MB parts above the
  2 GB GitHub release limit, deduplicated by basename, and published with
  `SHA256SUMS` + `NOTES.md` — the release plumbing mirrors the xaga project.

## Known gaps

1. **No boot-image build yet.**  The xaga project builds `boot.img` (Clang 18,
   mkbootimg v4 `header_size=1584`, DTB/reserved-memory assertions) in the same
   workflow; that logic should be lifted into a kernel-repo workflow and reused
   here for `--include-boot`.
2. **No kernel CI in the org yet** - modules come from a fresh clone each run
   (~15-20 min).  A kernel workflow publishing `Image`/`modules` artifacts would
   cut this to ~5 min and remove the duplicate config logic.
3. **Per-device quirks are mostly unwritten**: panel overlays, UCM card names,
   touch/fingerprint, and the MTK firmware container split for
   `--from-partitions`.
4. **Distro coverage**: only Debian is implemented; the xaga project also
   builds Arch Linux ARM and Ubuntu.  Adding them = one backend script each.
5. **Not yet built end to end in CI** - the workflow and scripts are validated
   statically (shell syntax, YAML, matrix generation, profiles), but the first
   real run will likely need one or two small fixes (dependency versions,
   mmdebstrap options, kernel config merge).

## Scope / honest assessment

This branch is infrastructure: it makes the rootfs side reproducible and gives
pearl and xaga identical, reviewable images.  It does **not** advance bring-up
by itself - in particular the baseband is untouched (on pearl the modem still
stops before `READY`, asserting in `ccismcore_ccci.c:2004`), so an image built
here boots to a desktop without cellular.  Its value is that the platform
knowledge (branch/config/DTS, userdata-rootfs convention, first-boot behaviour,
firmware policy) is written down once and exercised by CI, instead of living in
hand-built images.
