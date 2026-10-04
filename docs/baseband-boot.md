# Guarded Baseband Startup

The default baseband installer only installs tested user-space components.
To provision hardware startup for the reviewed qqcandy #532 integration:

```sh
sudo ./build.sh --device qqcandy --distro nura \
  --baseband-support /private/qqcandy-support
```

The private input contains `support-manifest.json` listing SHA256 values for
seven modules, `private/vendor-md/` and `private/overlay/` seeds. The module
hashes must match the checked-in reviewed integration. The supplied boot remains
external; this option does not build or flash it. Existing support/COW is never
overwritten. Do not publish this input or the resulting private image.

The preparer checks board, normal-boot DT, kernel release/notes, module hashes
and vermagic before loading. NV is mounted by exact partlabel as ext4 ro,noload;
preexisting writable/wrong mounts are refused. CCIF is loaded only after the
MD power domain is on. Partial/unknown loaded CCCI is not adopted or unloaded.
Vendor data remains hash-checked; mutable COW is never compared to seed hashes.

OpenRC and systemd preserve the existing owner/MM service boundary. The owner
has at most 86400 seconds; MM ends at least 30 seconds earlier with a 10-second
kill grace. Manual stop ordering ends MM before owner. No automatic respawn.
The lifetime record includes boot ID, process start ticks and monotonic time.
Distribution MM is inhibited to prevent a second D-Bus owner. A kernel mismatch
refuses startup instead of guessing that equal vermagic is enough.

Provisioning does not imply working radio. On Nura the current service chain
reached MD READY and private mtk-soc discovery. Standard selection of the present
SIM cleared sim-missing; MM now searches without registering. This is not an
automatic SIM-selection policy and does not establish why RF registration fails.
Cold boot, registration, mobile data, SMS and IMS remain separate acceptance
steps. Logs and COW are private; rollback configuration must preserve that store.
