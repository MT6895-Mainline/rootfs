# MT6895-Mainline rootfs

Flashable rootfs images for the MT6895 devices supported by
[MT6895-Mainline/linux](https://github.com/MT6895-Mainline/linux).

This repository is the rootfs half of the platform: it builds userspace images
and the kernel modules that must match the kernel you flash.  The kernel,
initramfs and boot-image side stays in the kernel repository.

**Landing now: `pearl` and `xaga`.**  `xaga-6.18`, `qqcandy` and `rubens` are
already wired up in `devices/` and can be enabled with the `devices` input.

| device | profile | kernel branch | kernel | config | modules dir (`uname -r`) | rootfs label |
|---|---|---|---|---|---|---|
| `pearl` (Redmi Note 12T Pro) | `devices/pearl.conf` | `7.2-mt6895-xiaomi-pearl` | 7.2.7 | `configs/pearl-7.2.7.config` (pinned) | `7.2.7+` (verified) | `archpearl` |
| `xaga` | `devices/xaga.conf` | `7.2-mt6895-xiaomi-xaga` | 7.2.0 | `xaga.config` | `7.2.0+` (assumed) | `xaga-rootfs` |
| `xaga-6.18` | `devices/xaga.conf` | `6.18-mt6895-xiaomi-xaga` | 6.18.0 | `xaga.config` | `6.18.0+` (assumed) | `xaga-rootfs` |
| `qqcandy` (OPPO K10 / Ace Racing) | `devices/qqcandy.conf` | `6.18-mt6895-oplus-qqcandy` | 6.18.0 | `qqcandy.config` | `6.18.0+` (assumed) | `mt6895qqcandy` |
| `rubens` (port) | `devices/rubens.conf` | `port/rubens-clean` | 7.2.0 | `rubens.config` | `7.2.0+` (assumed) | `mt6895rubens` |

The `modules dir` column has to match the device exactly, otherwise the image
boots without any modules; every image ships a `KERNEL-INFO-<device>.txt` that
states what it was built for, and `kernel_localversion` overrides the assumption
for a device whose kernel reports something else.

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
out/Image-<device>                      # kernel the modules were built for
out/dtb-<device>.dtb                    # when the branch builds one separately
out/KERNEL-INFO-<device>.txt            # which `uname -r` these modules need
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

The **boot image** is not packed here: that needs the kernel repository
(kernel + initramfs + embedded DTB, MTK v4 header).  What the release does give
you is a matching pair — `Image-<device>` plus the modules inside the rootfs
image — so a kernel and its modules cannot drift apart.

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
configs/<device>.config  kernel configs read off real hardware (pinned per profile)
configs/mt6895-fixups.config  disables drivers the branches cannot compile
overlay/common/          first-boot service, sysctl, shared files
overlay/<device>/        optional per-device quirks
tools/extract-firmware.sh, install-firmware.sh
```

## Design notes

* **Modules are built here, not downloaded.**  The kernel branch is checked out,
  configured exactly as the kernel is configured and `modules_install` goes
  straight into the rootfs, so `vermagic` cannot drift.
* **`pearl` builds from the config the running kernel was built from**
  (`KERNEL_FULL_CONFIG="configs/pearl-7.2.7.config"`, read off the device with
  `zcat /proc/config.gz`).  The branch's `defconfig + pearl.config` path is not
  enough on this tree: expanding the arm64 defconfig switches on MediaTek audio
  drivers (`mt8183`, `mt8188`) whose source does not compile on the branch, while
  the device's own config keeps them off.  The pinned config builds 1391 modules
  and its vermagic inputs (`SMP`, `PREEMPT`, no `MODVERSIONS`, no `MODULE_SIG`,
  empty `LOCALVERSION`) match the device.  The other devices still use the
  fragment path until someone can read a config off the real hardware.
* **The module directory must equal `uname -r`.**  A git kernel build that is not
  at a tag reports `7.2.7+`, while the same source exported as a tarball (what CI
  checks out) reports `7.2.7`; `modules_install` then writes to a directory the
  kernel never reads.  `KERNEL_LOCALVERSION="+"` in the device profile pins the
  suffix, and `build.sh` asks the tree for its real `kernelrelease` (after a
  config sync, since `include/config/kernel.release` is cached) instead of
  trusting the `Makefile`.  It also checks the directory `modules_install`
  actually used and takes that as the truth.
* **Any other kernel can be matched too**: `--kernel-config /path/to/.config`, the
  `kernel_config_url` workflow input, or `KERNEL_FULL_CONFIG` in the profile;
  `--kernel-localversion ""` clears the pinned suffix.
* `pearl` uses `KERNEL_MAKE_ARGS="LLVM=1"` because the pearl boot images in use
  are clang builds.
* Images are sparse (`img2simg`) and gzipped, split into 1900 MB parts above the
  2 GB GitHub release limit, deduplicated by basename, and published with
  `SHA256SUMS` + `NOTES.md` — the release plumbing mirrors the xaga project.

## Known gaps

1. **No boot image (yet).**  Each release carries `Image-<device>` (and
   `dtb-<device>.dtb` where the branch builds one separately), built from the
   same config as the modules in the rootfs image, but nothing packs them into a
   flashable `boot.img`: that needs the MTK v4 header and the reserved-memory
   assertions the xaga project already has (Clang, mkbootimg `header_size=1584`).
   That belongs in a kernel-repo workflow; this repository deliberately ships the
   kernel and rootfs as a matched pair instead of re-implementing the packing.
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
