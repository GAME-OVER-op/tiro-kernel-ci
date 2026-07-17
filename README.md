# tiro-kernel-ci  -  Kurumi Kernel

CI that downloads every required source and builds the **Kurumi Kernel** (and,
optionally, a full ROM) for **Nubia / RedMagic tiro (NX769J / NX769S, RedMagic 9
Pro)** - Snapdragon 8 Gen 3 / SM8650 "pineapple", Linux 6.1, LineageOS 23.2.

## Two workflows
| Workflow | Builds | Artifact |
|---|---|---|
| `.github/workflows/build-kernel.yml` | Kernel only + `Kurumi_kernel_build<N>.zip` | `tiro-kernel` |
| `.github/workflows/build-rom.yml` | Full LineageOS 23.2 ROM | `tiro-rom` |

## In-kernel battery tweak (overlay.d)
The battery tuning ships inside the kernel flash - no separate Magisk module.
`anykernel/ramdisk/overlay.d/` is injected into the device ramdisk (`init_boot`
on GKI) and imported by Magisk, which runs `kurumi_battery` on boot:
- WALT smoothing: `up_rate_limit_us=1000`, `down_rate_limit_us=2000`, `hispeed_load=90`.
- Fewer VM wakeups: `dirty_writeback_centisecs=1500`, `stat_interval=10`, MGLRU `min_ttl_ms=1000`.

WALT comes up late at boot, so the script waits 5 min then applies once (values
are stable once written). Only `/sys` + `/proc` are written - reversible, no
partition writes, no log file. Requires Magisk (root). Tune values at the top of
`anykernel/ramdisk/overlay.d/sbin/kurumi_battery`. Revert: reflash stock `init_boot`.

## Build identity
`/proc/version` is forced to `(kurumi@dev)` with the real build time by hard-overriding
`scripts/mkcompile_h` (Kleaf otherwise pins `build-user@build-host` + epoch-0/1970).

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
