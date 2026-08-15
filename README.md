# tiro-kernel-ci  -  Kurumi Kernel

CI that downloads every required source and builds the **Kurumi Kernel** (and,
optionally, a full ROM) for **Nubia / RedMagic tiro (NX769J / NX769S, RedMagic 9
Pro)** - Snapdragon 8 Gen 3 / SM8650 "pineapple", Linux 6.1, LineageOS 23.2.

## Two workflows
| Workflow | Builds | Artifact |
|---|---|---|
| `.github/workflows/build-kernel.yml` | Kernel only + `Kurumi_kernel_build<N>.zip` | `tiro-kernel` |
| `.github/workflows/build-rom.yml` | Full LineageOS 23.2 ROM | `tiro-rom` |


## Current build plan

Kernel workflow now treats the Google GKI base as a moving `android14-6.1` branch instead of pinning comments/checks to one sublevel. The diagnostic check expects the neutral pattern:

```text
6.1.*-android14-11-kurumi-dev-GAME-OVER-op
```

The flashable AnyKernel package can ship up to three real kernel images and shows them in a volume-key scrolling menu:

1. `Stock` - no root.
2. `KernelSU` - KernelSU-Next only.
3. `KSU + susfs` - KernelSU-Next plus susfs, only shown when that image actually built and passed `CONFIG_KSU_SUSFS=y` verification.

Vol Down moves the cursor; Vol Up selects, matching the Rust profile selector.

## In-kernel battery tweak (overlay.d)
The battery tuning ships inside the kernel flash - no separate Magisk module.
`anykernel/ramdisk/overlay.d/` is injected into the device ramdisk (`init_boot`
on GKI) and imported by Magisk, which runs `kurumi_battery` on boot:
- WALT smoothing: `up_rate_limit_us=1000`, `down_rate_limit_us=2000`, `hispeed_load=90`.
- Fewer VM wakeups: `dirty_writeback_centisecs=1500`, `stat_interval=10`, MGLRU `min_ttl_ms=1000`.
- UFS/read-ahead profile after `boot_completed + 90s`:
  - `eco`: `clkgate=1`, `clkscale=1`, `read_ahead_kb=128`.
  - `balance`: `clkgate=1`, `clkscale=1`, `read_ahead_kb=512`.
  - `full`: `clkgate=1`, `clkscale=0`, `read_ahead_kb=2048` so UFS can still sleep at idle.
- Wi-Fi sleep/push profile after `boot_completed + 90s`:
  - `eco` / `balance`: delayed push. Wi-Fi stays ON, Android background scan/perf knobs are disabled, and only the direct WLAN endpoint `power/wakeup` is disabled. The PCIe parent chain is not touched.
  - `full`: soft push. Wi-Fi stays ON, Android background scan/perf knobs are disabled, and direct WLAN wakeup is kept/enabled so push notifications are close to stock.

The Rust daemon is launched either through Magisk `overlay.d` or, on pure
KernelSU/KSU+SuSFS installs without Magisk, through
`/data/adb/modules/kurumi_kernel/service.sh`. It waits 90 seconds after
`boot_completed` before applying the selected profile. Only `/sys` + `/proc` +
Android shell settings are written - reversible, no partition writes, no log
file. Choosing `Skip` removes the Kurumi runtime path.

Screen-off autonomy is kernel-assisted: when the built Image contains
`CONFIG_KURUMI_SCREEN_STATE=y`, the kernel exposes a tiny read-only bridge at
`/sys/kernel/kurumi_screen/`:

```text
state     # on / off / unknown
seq       # increments when state changes
since_ms  # milliseconds since last change
poll_ms   # recommended daemon poll delay: 30s off, 60s on/unknown
```

The daemon reads only this cheap sysfs state. It does not call `dumpsys`,
`cmd power` or Binder-based Android APIs to detect the screen. After the screen
stays off for 30 seconds it temporarily applies an Eco-like CPU/UFS fallback;
when the screen turns on it restores the selected flash-time profile. Touch boost
is also suppressed while the kernel reports the screen as off.


## Kernel-only daily-use / autonomy changes
The kernel workflow applies the autonomy layer to the **actual common GKI Image**, not only to the vendor fragment:

- `CONFIG_KURUMI_SCREEN_STATE=y` adds the minimal `/sys/kernel/kurumi_screen` bridge used by the daemon.
- `CONFIG_WQ_POWER_EFFICIENT_DEFAULT=y` is requested in `common/arch/arm64/configs/gki_defconfig` so kernel workqueues prefer lower-power execution by default.
- `CONFIG_LRU_GEN=y` and `CONFIG_LRU_GEN_ENABLED=y` are requested in the common GKI config so MGLRU is enabled by default.
- `CONFIG_RCU_LAZY=y` is requested when the branch exposes it, and `CONFIG_RCU_LAZY_DEFAULT_OFF=y` is removed so lazy RCU callbacks are not built but disabled by default.
- Release-heavy options are removed from the built Image path: `CONFIG_UBSAN`, `CONFIG_PM_DEBUG`, `CONFIG_PM_ADVANCED_DEBUG`, `CONFIG_THERMAL_STATISTICS`, and `CONFIG_THERMAL_EMULATION`. `CONFIG_KASAN` stays enabled because this QCOM GKI KMI expects its symbols.
- CI extracts the final config from the built Image and fails the build if the screen bridge, workqueue power mode, MGLRU, IPv6 NAT, or release-debug cleanup did not actually land.
- A `kurumi-kernel-config-audit` artifact is uploaded from the built Image, including `final.config`, `kernel.release`, optional `Module.symvers`, and a release/debug audit for MGLRU, RCU lazy, PSI, uclamp, EAS, cpuidle, workqueue and heavy debug symbols.
- SuSFS variant integration uses plain `KernelSU-Next legacy` plus the matching `susfs4ksu` KSU-side patch instead of mismatched pre-integrated susfs tags.

## Build identity
`/proc/version` is forced to `(kurumi@dev)` with the REAL build time by hard-overriding
`scripts/mkcompile_h`: it sets `KBUILD_BUILD_USER/HOST` and, crucially, `SOURCE_DATE_EPOCH`
(Kleaf otherwise pins `build-user@build-host` + epoch-0, i.e. 1970).

> Install flow: the kernel is flashed to `boot`; then a second AnyKernel pass
> re-targets `init_boot` (`reset_ak` + `setup_ak`) and repacks ONLY its ramdisk with
> overlay.d added. Device check is OFF (`do.devicecheck=0`).

## Flashing (test in RAM first)
```bash
adb reboot bootloader
fastboot boot boot.img   # RAM only, writes nothing
```
Only after it is proven stable, flash `Kurumi_kernel_build<N>.zip` in recovery.

## License
MIT (see `anykernel/LICENSE`).
