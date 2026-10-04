# MT6895-Mainline rootfs

ARM64 userspace root filesystem builds for MT6895 devices. Kernel, DTB,
initramfs and boot images belong to the separate boot-chain repositories.
Device-specific hardware assumptions live in explicit profiles.

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
cd rootfs
sudo bash ./build.sh --device qqcandy --distro mobian
sudo bash ./build.sh --device qqcandy --distro arch
sudo bash ./build.sh --device qqcandy --distro nura
```

Default UI is Phosh; `--ui console` selects a console build.
Mobian/Debian use Phrog/Greetd; Arch uses its packaged GDM with the default
user's Phosh Wayland session, and Nura uses its native Phosh/OpenRC packages.
`--suite` overrides a backend's default (Arch currently accepts only rolling,
the pinned Nura backend only edge). `--mirror` selects the Debian mirror.
Actions **rootfs** offers a strict device/distribution matrix and optionally
publishes a **draft** release only after every selected build succeeds.
Workflow parameters are not interpolated as shell source.

Every build is userspace-only. To export a tar archive without an ext4 image:

```sh
sudo bash ./build.sh --device qqcandy --distro mobian \
  --no-image --ui console --tar --stage-rootfs 1
```

`--rootfs-only` remains a compatibility alias for `--no-image --tar`.
The default still produces a rootfs ext4 image. All images require a separately
validated device boot; the builder never builds or flashes that boot.
Nura Phosh includes the complete `_pmb_recommends` lists from the pinned
Phosh, GNOME Mobile, GNOME and base UI recipes, including fonts and languages.
Direct APK installation alone does not expand those lists.
See [Nura application selection](docs/nura-apps.md) for the upstream sources,
complete package list and the distinction between installed apps and hardware
support. The qqcandy Nura, Arch and Mobian userspace builds at `1495876` passed CI.
On-device Nura checks confirmed
all 40 recommendation packages, 17 main launchers and activation of Contacts
and Text Editor. This is not acceptance of every app's hardware features.
qqcandy Phosh builds show all installed applications by default, including
those not marked adaptive. Cutout candidates remain on-device experiments
until their layout is accepted; they are not yet included in these images.

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

Kernel branches above are external references, not rootfs build inputs.
The legacy `xaga-6.18` workflow alias only selects xaga userspace and its
artifact suffix. It no longer builds or selects a different kernel.
Locally use `--device xaga --name-suffix -6.18` for that naming convention.
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
qqcandy now defaults to automatic baseband user-space installation at build
time. Owner and a matching complete MM/mtk-soc bundle are resolved from the
organization repositories, tested and installed in an isolated versioned
directory, leaving distribution MM/client libraries intact. `--baseband off`
disables this integration; `on` requires a reviewed device profile.
`--baseband-owner-ref` and `--baseband-mm-ref` accept `latest` (the default)
or full source commits. The manifest records the resolved pair.
See [baseband installation](docs/baseband.md) for the standalone offline
installer and layout. Without private board support, services remain disabled.
`--baseband-support /private/support` imports a checked #532 support manifest
and enables guarded owner/MM startup, including exact kernel/modules, read-only
NV mounts and a 24-hour owner limit. It never replaces an existing COW store.
Such images contain private vendor data and device-specific NV seeds: do not
publish them. The boot chain has run on Nura; a new cold boot and network/IMS
acceptance are still separate. See [guarded startup](docs/baseband-boot.md).

qqcandy/Nura/Phosh now defaults to the device-tested native cutout integration
(`--phosh-cutout off` opts out). It rebuilds pinned Phosh 0.57.0 with the Alpine
patch and a native top-bar patch, then installs a private shell/library for
the user session and Phrog 0.53.0. Stock APK files remain intact. Other distro
versions and landscape use are not claimed fully adapted; see
[display integration](docs/phosh-cutout.md).

## Userspace Artifacts

```text
rootfs-<device>-<distro>[-<suffix>]-<timestamp>-sparse.img[.gz]
rootfs-<device>-<distro>[-<suffix>]-<timestamp>.tar.zst   (--tar)
USERSPACE-INFO-<device>-<distro>.txt
MODULES-<device>-<distro>.json                         (external import only)
SHA256SUMS
```

No kernel checkout, compiler, DTB or initramfs build is part of this pipeline.
Legacy kernel/initramfs build flags fail with a migration message. Retained
`configs/` files are historical references, not active build inputs.

Optional matching modules can be imported from an external kernel build:

```sh
sudo bash ./build.sh --device qqcandy --distro nura \
  --modules /path/to/lib/modules/6.18.0+ --kernel-release 6.18.0+
```

Both flags are required together. The importer checks the single release
directory, ARM64 relocatable ELF headers, release and consistent full vermagic,
rejects symlinks/special files (excluding build/source) and records source hashes.
It never strips, rebuilds, loads or forces modules. `depmod` regenerates indexes.
The manifest is also stored at `/usr/share/mt6895-build/kernel-modules.json`.
These checks do **not** prove boot configuration, symbol CRC or signature-policy
compatibility: supply modules from the exact validated boot build. Without an
import, module-dependent hardware needs matching modules installed separately.

This repo does **not** build boot.img or flash anything. Userdata deployment
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
The first-boot service grows ext4 and generates per-installation SSH keys and
machine identity. OpenRC images omit machine-id; systemd images keep its empty
stub. Identity initialization precedes D-Bus, even with an old completion marker.
Phosh builds check target compiled schemas; Nura installs Stevia's split schemas.

## Verification

### Historical Full Builds (2026-10-03)

| qqcandy / Phosh | Full build | Build source / evidence |
| --- | --- | --- |
| Arch Linux ARM / GDM | Passed: Image, DTB, modules, tar, ext4 and checksums | `01475dc`, [job](https://github.com/MT6895-Mainline/rootfs/actions/runs/37047995064/job/110974148298) |
| Nura / OpenRC | Passed: Image, DTB, modules, tar, ext4 and checksums | `01475dc`, [job](https://github.com/MT6895-Mainline/rootfs/actions/runs/37047995064/job/110974148374) |
| Mobian / Phrog | Passed: Image, DTB, modules, tar, ext4 and checksums | `5318d97`, [job](https://github.com/MT6895-Mainline/rootfs/actions/runs/37083419238/job/111088654679) |

All three historical distributions' artifacts passed independent checksum,
rootfs-content and read-only ext4 checks. Those builds used the former combined
kernel pipeline. They do not validate the current userspace-only pipeline or
retroactively contain the identity/schema/application-list fixes.

These complete-image snapshots precede the automatic baseband installer.
Their original accepted artifacts remain unchanged; installation tests for
the new bundle are a separate acceptance stage, not retroactive hardware proof.
In separate offline ARM64 Mobian, Arch and Nura rootfs copies, the new installer
passed native builds, owner protocol checks, all 18 MM suites, version execution,
installation/content contracts and same-source repeat installation. Services
were not started. See [baseband validation](docs/baseband.md#validation-scope).

### Current Fixes

The original validated qqcandy #532 boot starts the tested Nura userspace.
Empty machine-id and missing Stevia schemas were repaired without a kernel
change; the user confirmed desktop/keyboard, then Wi-Fi/Bluetooth after another
boot. This is not baseband/IMS acceptance. Offline builder tests cover identity
ordering/failure, schema queries, full pinned Nura recommendations and external
module imports. Separate ARM64 first-boot tests cover nine cases.
The userspace-only three-distribution matrix passed at `1495876` in
[run 37124423466](https://github.com/MT6895-Mainline/rootfs/actions/runs/37124423466).
Those artifacts include the application/schema/interface fixes, not the newer
native cutout or guarded boot provisioning. The `ef798c3` all-app visibility
override also passed checks and native ARM64 schema validation.

Auxiliary ap0/wlan1/p2p0 interfaces are unmanaged by default on qqcandy; wlan0
and USB networking remain managed. Developer tooling can opt those interfaces
back in. On the current Nura phone the user has accepted native portrait cutout
placement in both the desktop and Phrog login page, and keyboard vibration after
the precise AW8697 feedbackd rule. These fixes now enter the build pipeline;
this is not evidence that a newly generated whole image was flashed or booted.
The offline native cutout installer completed compilation, all 36 unit tests,
ABI comparison and private installation. Guarded owner/MM startup reached READY
on #532 with all NV mounts read-only. Selecting the present SIM through the
standard MM interface cleared `sim-missing`; MM now searches but is unregistered.
Network/IMS and actual cold-boot autostart remain unvalidated.

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

When Waydroid's ARM64 interpreter shadows QEMU, use the existing
`sudo tools/with-qemu.sh <build-command>` private user/binfmt namespace wrapper.
Do not disable Waydroid, reset host handlers or call pmbootstrap shutdown.
