# MT6895-Mainline rootfs

Root filesystem builds for MT6895 devices, with matching kernel Image, DTB
and modules. Device-specific hardware assumptions live in explicit profiles.

## Distributions

| Backend | Default suite | Bootstrap / init | Desktop |
| --- | --- | --- | --- |
| `mobian` | trixie | authenticated Debian bootstrap, Mobian archive / systemd | mobian-phosh |
| `arch` | rolling | signed official Arch Linux ARM tarball / systemd | Phosh |
| `nura` | edge | pinned pmbootstrap/pmaports / OpenRC | Phosh |
| `debian` | trixie | mmdebstrap / systemd | Phosh |

Nura [renamed from postmarketOS in September 2026](https://nura.eco/blog/2026/09/27/nura-rename/).
The upstream tooling, repository and package identifiers are still named
pmbootstrap/postmarketOS during the transition. `--distro pmos` remains an
alias; this backend installs real Nura packages, not a renamed Alpine image.
Its QEMU ARM64 profile is used only to bootstrap the architecture: no QEMU
device package, kernel or boot recipe is installed.

## Build

On Debian/Ubuntu, as root, install the dependencies listed in
`.github/workflows/rootfs.yml`, including registered ARM64 QEMU binfmt.

```sh
git clone https://github.com/MT6895-Mainline/rootfs
git clone -b 6.18-mt6895-oplus-qqcandy https://github.com/MT6895-Mainline/linux
cd rootfs
sudo bash ./build.sh --device qqcandy --distro mobian --kernel-repo ../linux
sudo bash ./build.sh --device qqcandy --distro arch --kernel-repo ../linux
sudo bash ./build.sh --device qqcandy --distro nura --kernel-repo ../linux
```

Default UI is Phosh; `--ui console` selects a console build.
`--suite` overrides a backend's default (Arch currently accepts only rolling,
the pinned Nura backend only edge). `--mirror` selects the Debian mirror.
Actions **rootfs** offers a strict device/distribution matrix and optionally
publishes a **draft** release only after every selected build succeeds.
Workflow parameters are not interpolated as shell source.

User-space-only validation avoids compiling a kernel:

```sh
sudo bash ./build.sh --device qqcandy --distro mobian \
  --rootfs-only --ui console --tar --stage-rootfs 1
```

These outputs are explicitly named `userspace-only-*` and are **not deployable**.
No rootfs image, kernel Image or kernel modules are produced in this mode.

On hosts whose ARM64 binfmt handler is occupied by Android/Waydroid, the
optional `tools/with-qemu.sh` provides private user/mount/PID/binfmt namespaces
without replacing global handlers. It requires a fresh root-owned output
directory. It works for Debian-family bootstrap; pmbootstrap requires
privileged device-node creation and should run on a standard root build
host/CI runner instead. Do not disable unrelated host interpreters.

## Devices

| Profile | Kernel branch | userdata / nvdata |
| --- | --- | --- |
| qqcandy (21143 / 22801) | 6.18-mt6895-oplus-qqcandy | measured sdc80 / sdc10 |
| pearl | 7.2-mt6895-xiaomi-pearl | device profile |
| xaga | 7.2-mt6895-xiaomi-xaga | device profile |
| rubens | port/rubens-clean | provisional profile |

The workflow's `xaga-6.18` variant uses the xaga profile and overrides the
kernel ref to `6.18-mt6895-xiaomi-xaga`. Locally use `--device xaga
--kernel-ref 6.18-mt6895-xiaomi-xaga --name-suffix -6.18`.
Partition numbers are **not** SoC-wide facts. Never apply another board's
partition, charger, GPIO, firmware, touch or fingerprint configuration.

## Boot Chain and Quirks

- [linux](https://github.com/MT6895-Mainline/linux): kernel and device trees.
- [initramfs/qqcandy-mt6895](https://github.com/MT6895-Mainline/initramfs/tree/qqcandy-mt6895):
  guarded qqcandy init, source-only archive, read-only nvdata calibration copy.
- [quirks/qqcandy-mt6895](https://github.com/MT6895-Mainline/quirks/tree/qqcandy-mt6895):
  board-specific UCM. The qqcandy profile installs a pinned revision.
- [vaapi-mtk-vcp](https://github.com/MT6895-Mainline/vaapi-mtk-vcp):
  user-space video driver built inside the target rootfs, with pinned source.

qqcandy UCM uses PCM2/DL2 for both speaker and headphones, not Xaga's
PCM0/DL1 headphone route. Xaga's microphone-switch daemon is not installed.
VCP driver installation does **not** validate or activate qqcandy's VCP
hardware/firmware ABI. No global `LIBVA_DRIVER_NAME` is exported.
`--vaapi off` skips building the component; `on` requires a configured profile.
Neither CCCI owner services nor experimental ModemManager forks are installed
or enabled automatically. IMS/VoLTE are not claimed working by this builder.

## Kernel and Artifacts

```text
rootfs-<device>-<distro>[-<suffix>]-<timestamp>-sparse.img[.gz]
rootfs-<device>-<distro>[-<suffix>]-<timestamp>.tar.zst   (--tar)
Image-<device>-<distro>
dtb-<device>-<distro>.dtb
KERNEL-INFO-<device>-<distro>.txt
SHA256SUMS
```

A fresh source export builds **Image**, the requested board DTB and modules.
Module-directory mismatches fail rather than silently changing the expected
release. `KERNEL-INFO` records the resolved commit, configuration and release.
Flash/use Image, DTB and rootfs modules as a matched set: a shared `uname -r`
alone does not prove matching source, configuration or symbol versions.
Existing-device matching can use `--kernel-config FILE` and
`--kernel-localversion SUFFIX`; do not mix a newly built rootfs with an old boot
image merely because both claim 6.18.

This repo does **not** pack boot.img or flash anything. Userdata deployment
erases existing user data; boot-chain validation and board-specific recovery
must precede deployment. Do not assume an in-system reboot can enter fastboot.
Use the documented qqcandy deployment procedure and keep a verified backup.

## Firmware and Accounts

No extracted vendor firmware or device-specific calibration is injected by
public CI. Standard distribution packages may include redistributable firmware
under their own licenses. A private local build may use `--firmware DIR`;
never publish its archives without checking licensing and excluding NVRAM.
Firmware extraction helpers remain in `tools/`.

Default local user is the profile's `DEFAULT_USER` (qqcandy: `mobian`), PIN
**1234**. Change it on first login or pass `--user-password` for a private build.
Root is locked unless explicitly configured locally; SSH root/password login
is disabled. Use SSH public keys for remote access. Public workflow inputs
do not accept passwords, WiFi credentials or private firmware URLs.
The first-boot service grows ext4 and generates per-installation SSH keys.

## Verification

```sh
python3 -m unittest discover -s tests -v
for f in build.sh distros/*.sh tools/*.sh; do bash -n "$f"; done
```

Checks exercise matrix validation and shell contracts. Real ARM64 rootfs
builds are separate workflow runs; a passing syntax check is not a build.
Likewise build success is not phone boot, touch/audio, modem or VCP runtime
acceptance. Hardware validation must preserve the stable boot/NV baseline.

### Build-Only Workaround

Arch package downloads under QEMU cannot use Landlock or seccomp filters. The builder passes
`--disable-sandbox` only to its package-install invocations; package
signatures remain checked, and the deployed
pacman configuration is unchanged. Remove this workaround once the emulation
environment supports both mechanisms. See the [pacman manual](https://man.archlinux.org/man/pacman.8.en).
