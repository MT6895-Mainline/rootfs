# Baseband Userspace Installation

qqcandy builds now default to `--baseband auto`. The builder resolves the
organization's owner `main` and MM `mtk-soc-1.24.2` branch once, checks out the
resolved commits, builds/tests them in the target ARM64 rootfs, and installs
a versioned bundle. No distribution package repository is required.

`latest` means the selected repository branch at build time, not automatically
executing a changing upstream HEAD at every boot. Full commit IDs reproduce a
known source pair:

```sh
sudo bash build.sh --device qqcandy --distro mobian --kernel-repo ../linux \
  --baseband on \
  --baseband-owner-ref f6147b10cf7ef95932674506fbdfb7f3d67a1067 \
  --baseband-mm-ref 7b55aa04ad250dec7bd0d2fb5b458cd3df9d0763
```

Use `--baseband off` to retain distribution-only MM. `on` rejects devices
without a reviewed profile. The same installer works on an existing offline
rootfs without rebuilding a kernel:

```sh
sudo bash tools/install-baseband.sh --root /path/to/offline-rootfs \
  --device qqcandy --distro mobian --jobs 2
```

It refuses `/`, non-ARM64 init, unsupported boards, arbitrary ref expressions,
escaping installation paths, concurrent installations, and conflicting MTK
udev rules. It does not restart services, modprobe, mount NV, or start MD.
Package installation uses a temporary build DNS file and restores the original
file/symlink on success or failure. Repeating the same source pair validates
and selects the existing bundle without overwriting or recompiling it.
To select a retained older bundle, pass its two exact commits; do this only
on an offline rootfs and preserve the hardware deployment constraints.

## Validation Scope

The owner `f6147b10cf7ef95932674506fbdfb7f3d67a1067` and MM
`7b55aa04ad250dec7bd0d2fb5b458cd3df9d0763` pair passed native ARM64
build/install tests in separate Mobian, Arch Linux ARM and Nura rootfs copies.
Each ran the owner's 12 checks (one Meson suite), all 18 suites in this
generic + mtk-soc MM configuration, and the real version-only entrypoints.
Rootfs content contracts and repeat installation also passed. The 24 offline
builder tests include failed-install DNS restoration, previous-selection
preservation, corrupt-cache rejection and disabled-service checks.
Offline systemd unit loading was also checked; it exposed and prevented a
duplicate `BusName` declaration with the retained distribution MM unit.

These are userspace installation tests, not replacement full-image workflow
runs or phone tests. The previously accepted Image/DTB/rootfs artifacts were
not modified and do not contain this bundle.

## Runtime Layout

- `/usr/lib/mtk-ccci/releases/<owner-commit>-<mm-commit>/`: immutable source pair.
- `/usr/lib/mtk-ccci/current`: selected, tested bundle; older releases retained.
- `/usr/libexec/mtk-ccci/`: launcher, private MM entrypoint and bounded READY gate.
- `/usr/share/mt6895-build/baseband.json`: resolved commits and validation scope.
- systemd or OpenRC: installed `mtk-ccci-owner` and `mtk-modemmanager` units.

The complete MM daemon, plugin and its `libmm-glib` are built together.
The launcher selects only that bundle's private library directory. It does
not overwrite the distribution MM, client libraries, global linker config,
or place an internal-ABI plugin into an unrelated MM version. This matters
for Nura's newer MM version. Clients still use the normal ModemManager D-Bus API.

## Hardware Startup Is Separate

Units are installed **disabled**, not presented as a validated boot service.
The bundle manifest explicitly records `autostart=false` and
`hardware_validated=false`. Successful compilation, version execution and
protocol tests do not prove SIM registration, data, SMS, voice or IMS.

Before enabling the owner, board deployment must provide the verified module
loading/readiness gate, matching kernel release/notes, private firmware and
configuration, read-only protected mounts, and bounded private write storage.
The owner's existing fail-closed preflight remains intact. MM starts only
after MD READY, with a bounded read-only wait; a second MM must not run.
At deployment, the distribution MM must be stopped and disabled/masked (or
removed from the OpenRC runlevel) before selecting the private service, including
its D-Bus activation path. The private systemd unit uses `Type=exec` rather
than reserving the same `BusName` as the retained distribution unit, and
orders startup after that unit's stop. These are deployment prerequisites,
not actions performed by the installer.

No live-system updater or first-boot network downloader is enabled. Do not
hot-switch the bundle or restart its owner while MD is active. A newer source
pair is not a guarantee of working hardware; deployment and controlled
device acceptance remain necessary.
