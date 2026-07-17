# tiro-kernel-ci  -  Kurumi Kernel

CI that **downloads every required source and builds** the **Kurumi Kernel** (and,
optionally, a full ROM) for **Nubia / RedMagic tiro (NX769J / NX769S, RedMagic 9
Pro)** - Snapdragon 8 Gen 3 / SM8650 "pineapple", Linux 6.1, LineageOS 23.2
(Android 16). No need to upload heavy source archives.

> **Kernel base = the original nubia / AOSP GKI base, NOT OnePlus.** The kernel
> workflow builds the GKI Image from pristine **AOSP `kernel/common` `android14-6.1`**
> (the exact GKI branch the device's stock / LineageOS 23.2 ROM tracks) and overlays
> the **nubia msm-kernel + device-trees** on top. Because that GKI is KMI-compatible
> with the device's stock vendor modules, no ABI-breaking symbol drops / module trims
> are needed. **Always test with `fastboot boot boot.img` (RAM), never
> `fastboot flash boot`, until the kernel is proven stable.**

---

## Two workflows

| Workflow file | Builds | Output | Runner |
|---|---|---|---|
| `.github/workflows/build-kernel.yml` | **Kernel only** (standalone Kleaf/Bazel GKI) | `boot.img`, `vendor_boot.img`, and `Kurumi_kernel_build<N>.zip` (flashable Kurumi zip) - artifact **`tiro-kernel`** | fits a free GitHub-hosted runner |
| `.github/workflows/build-rom.yml` | **Full LineageOS 23.2 ROM** | `lineage-*.zip` + images - artifact **`tiro-rom`** | needs a large / self-hosted runner or a local PC |

Both apply the same kernel customizations, so the kernel inside the ROM matches the
one the kernel workflow produces.

## Layout
```
.github/workflows/build-kernel.yml   # kernel images + Kurumi flashable zip (lighter)
.github/workflows/build-rom.yml      # full LineageOS ROM (heavy)
anykernel/                           # Kurumi flasher (banner, version, overlay.d, installer)
local_manifests/nubia_tiro.xml       # ROM repos to pull
scripts/                             # Kleaf overlay fix-ups used by the kernel build
```

## Use
1. Push these files to a GitHub repo (keep paths).
2. **Actions -> Build tiro KERNEL -> Run workflow** (recommended first).
3. Download from the run's **Artifacts** (`tiro-kernel`): flash `Kurumi_kernel_build<N>.zip`
   in recovery, or RAM-test `boot.img` via fastboot first.

---

## Kernel customizations (baked in automatically)

### Balanced power-saving (low risk, no GKI-ABI impact)
| Setting | Effect |
|---|---|
| `CONFIG_WQ_POWER_EFFICIENT_DEFAULT=y` | Non-urgent workqueues don't wake idle CPUs -> idle battery win |
| `# CONFIG_THERMAL_EMULATION` / `# CONFIG_THERMAL_STATISTICS` off | Drop pure-debug thermal overhead |
| `# CONFIG_PM_DEBUG` / `# CONFIG_PM_ADVANCED_DEBUG` off | Drop PM debug overhead |

### Boot-critical fix
`CONFIG_MODULE_SIG_PROTECT` is disabled in the common GKI defconfig so the kernel
accepts the stock `/system_dlkm` GKI modules (otherwise rfkill/bt/audio fail and the
boot animation hangs). A CI step extracts the built Image's config and **fails the
build** if the flag is still on - no "flash and find out".

### Build identity
`KBUILD_BUILD_USER=kurumi`, `KBUILD_BUILD_HOST=dev`, and a real build timestamp are
forced into `/proc/version` (job env + `--action_env` + an `mkcompile_h` stamp that
overrides Kleaf's reproducible epoch-0 default). `uname -r` carries the
`-kurumi-dev-GAME-OVER-op` LOCALVERSION while keeping the `-android14-11` KMI marker,
so ABI/module parity with the device is preserved.

---

## In-kernel battery tweak (overlay.d)

The battery/perf tuning ships **inside the kernel flash** - no separate Magisk
module. `anykernel/ramdisk/overlay.d/` is injected into the device ramdisk
(`init_boot` on GKI) and imported by Magisk, which runs `kurumi_battery` on
`sys.boot_completed`:

- **WALT cpufreq smoothing:** `up_rate_limit_us=1000`, `down_rate_limit_us=2000`,
  `hispeed_load=90` on every `walt` policy.
- **Fewer VM wakeups:** `vm.dirty_writeback_centisecs=1500`, `vm.stat_interval=10`,
  MGLRU `min_ttl_ms=1000`.

Only `/sys` + `/proc` are written - fully reversible, no partition writes, no log
file. Requires Magisk (root) present, which imports overlay.d. Tune the values at
the top of `anykernel/ramdisk/overlay.d/sbin/kurumi_battery`. **Revert:** reflash
stock `init_boot`.

---

## Flashing (fastboot) - test in RAM first
> Bootloader unlocked. Back up stock `boot` + `init_boot` first.

```bash
adb reboot bootloader
fastboot boot boot.img      # loads the kernel into RAM ONLY, writes NOTHING
```
- Boots and `/data` decrypts and stays stable -> the kernel is good.
- Hangs / bootloops -> hold Power ~10 s to reboot back into the untouched stock
  kernel. Nothing was written, nothing is damaged.

Only **after** it is proven stable in RAM, make it permanent by flashing
`Kurumi_kernel_build<N>.zip` in recovery (replaces the kernel inside `boot` and adds
the overlay.d tweak to `init_boot`; does not touch vbmeta).

> WARNING: do NOT `fastboot flash boot` an unverified kernel. RAM-boot first, every time.

---

## Where to make kernel edits later
- tiro config: `kernel/nubia/sm8650/arch/arm64/configs/oem/boards/tiro_diff.config`
  and platform `.../oem/pineapple_diff.config`
- source / drivers: `kernel/nubia/sm8650/...`
- device-tree overlays: `kernel/nubia/sm8650-devicetrees/qcom/tiro/`
- vendor kernel modules: `kernel/nubia/sm8650-modules/qcom/opensource/...`

## Display panel note
tiro panel = **BF068_RM692H0** (6.8" OLED, FHD+ 1116x2480, command mode, DSC),
discrete **60/120 Hz** only, no qsync/VRR. Adding 30/48/90 Hz needs vendor register
command sequences not present in the tree, so it is intentionally left out.

## ROM repos pulled (branch lineage-23.2)
| Path | Repo (nubia-sm8650-devs/...) |
|---|---|
| device/nubia/tiro | android_device_nubia_tiro |
| device/nubia/sm8650-common | android_device_nubia_sm8650-common |
| kernel/nubia/sm8650 | android_kernel_nubia_sm8650 |
| kernel/nubia/sm8650-devicetrees | android_kernel_nubia_sm8650-devicetrees |
| kernel/nubia/sm8650-modules | android_kernel_nubia_sm8650-modules |
| vendor/nubia/tiro | proprietary_vendor_nubia_tiro |
| vendor/nubia/sm8650-common | proprietary_vendor_nubia_sm8650-common |

## License
MIT (see `anykernel/LICENSE`).
