# tiro-kernel-ci

CI that **downloads every required repo and builds** for Nubia / RedMagic
**tiro (NX769J)** on **LineageOS 23.2** (Android 16, Snapdragon 8 Gen 3 / SM8650
"pineapple", Linux 6.1). No need to upload heavy source archives.

> **Kernel base = the ORIGINAL nubia/GKI base, NOT OnePlus.** The kernel workflow
> builds the GKI Image from pristine **AOSP `kernel/common` `android14-6.1`** (the
> exact GKI branch the device's stock / LineageOS 23.2 ROM tracks, ASB-2026-06-01)
> and overlays the **nubia msm-kernel + device-trees** on top. Because that GKI is
> KMI-compatible with the device's stock vendor modules, all the old OnePlus-base
> hacks (KMI symbol drops, module trims, custom `LOCALVERSION`) are gone -- those
> were what broke `/data`. **Always test with `fastboot boot boot.img` (RAM),
> never `fastboot flash boot`.**
>
> **Note on nubia OEM defconfig fragments** (`oem/pineapple_diff.config` +
> `oem/boards/tiro_diff.config`): these are intentionally NOT applied. They are meant
> for the full vendor `pineapple` build (perf/consolidate) where vendor drivers are
> `=y`; the bare `gki` target forces them to `=m` and the strict `check_merged_defconfig`
> aborts (`NFC_ST54J y->m`). Those peripheral drivers already exist as stock
> `vendor_dlkm` modules on the device, so the Image-only GKI build does not need them.

---

## Two workflows

| File | Workflow | Output | Runner |
|------|----------|--------|--------|
| `.github/workflows/build-kernel.yml` | **Build tiro KERNEL** | `boot.img`, `dtbo.img`, `vendor_boot.img` | fits GitHub-hosted (after disk fixes) |
| `.github/workflows/build-rom.yml` | **Build tiro ROM** | `lineage-*.zip` + images | **needs self-hosted / large runner or local PC** |

Both apply the same customizations (power-saving + kernel identity below), so the
kernel inside the ROM is the same one the kernel workflow produces.

## Files
```
.github/workflows/build-kernel.yml   # kernel images only (lighter)
.github/workflows/build-rom.yml      # full LineageOS ROM (heavy)
local_manifests/nubia_tiro.xml       # repos to pull
```

## Use
1. Create a GitHub repo, copy all files (keep paths), push.
2. Actions -> pick **Build tiro KERNEL** (recommended first) or **Build tiro ROM**
   -> **Run workflow**.
3. Download from the run's **Artifacts** (`tiro-kernel` / `tiro-rom`).

---

## Customizations baked in automatically (both workflows)

Injected at build time into
`kernel/nubia/sm8650/arch/arm64/configs/oem/pineapple_diff.config` — no fork needed.

### Balanced power-saving (low risk, reversible, no GKI-ABI impact)
| Setting | Effect |
|---|---|
| `CONFIG_WQ_POWER_EFFICIENT_DEFAULT=y` | Non-urgent workqueues don't wake idle CPUs -> idle battery win |
| `# CONFIG_THERMAL_EMULATION` / `# CONFIG_THERMAL_STATISTICS` off | Remove pure-debug thermal overhead |
| `# CONFIG_PM_DEBUG` / `# CONFIG_PM_ADVANCED_DEBUG` off | Remove PM debug overhead |
| `CONFIG_TCP_CONG_BBR=y` + `DEFAULT_BBR` + `NET_SCH_FQ` | More efficient networking |

### Kernel identity
| Where | Value | Result |
|---|---|---|
| `KBUILD_BUILD_USER` (job env) | `kurumi` | `/proc/version` author |
| `KBUILD_BUILD_HOST` (job env) | `dev` | -> `(kurumi@dev)` |

> **`CONFIG_LOCALVERSION="-GAME-OVER-op"` was intentionally REMOVED.** A custom
> `LOCALVERSION` changes the kernel vermagic / `uname -r`, which can make the stock
> vendor modules refuse to load -> storage/crypto fail -> **corrupted `/data`**
> (the brick that happened). The version string is kept stock for ABI parity; the
> `kurumi@dev` author still shows in `/proc/version` (that field does NOT affect
> module loading). ASCII on purpose; for the Japanese form (くるみ / デヴ) change the
> two `env:` values.

To revert any of these, delete the matching lines in the
"Apply tiro kernel customizations" step.

---

## Disk / "No space left on device"

The earlier `repo sync` failure was the runner running out of disk. Both
workflows fix it with:
- **`repo init --partial-clone --clone-filter=blob:none`** — biggest saver.
- **Swap 8192 -> 2048 MB** and **root-reserve 4096 -> 2048 MB** -> more space to
  `/mnt/src`.
- `df -h` diagnostics before/after sync.

Kernel build should fit a free runner. The **ROM** build likely still won't —
use a self-hosted / large runner (edit `runs-on:` in `build-rom.yml`) or your PC.

---

## Build locally (for when you do it on your PC)
```bash
mkdir tiro && cd tiro
repo init --git-lfs --no-clone-bundle --partial-clone --clone-filter=blob:none \
     -u https://github.com/LineageOS/android.git -b lineage-23.2
mkdir -p .repo/local_manifests && cp /path/to/nubia_tiro.xml .repo/local_manifests/
repo sync -c -j"$(nproc --all)" --force-sync --no-clone-bundle --no-tags --optimized-fetch
export KBUILD_BUILD_USER=kurumi KBUILD_BUILD_HOST=dev LOCALVERSION=""
# apply the power-saving + LOCALVERSION lines to
#   kernel/nubia/sm8650/arch/arm64/configs/oem/pineapple_diff.config
source build/envsetup.sh
breakfast tiro
mka bootimage dtboimage vendorbootimage -j"$(nproc --all)"   # kernel only
# brunch tiro                                                # full ROM
```
Outputs land in `out/target/product/tiro/`.

---

## Testing / flashing (fastboot)
> Bootloader unlocked. Back up stock images first.

### 1. ALWAYS test in RAM first (non-destructive, cannot brick)
```bash
adb reboot bootloader
fastboot boot boot.img      # loads the kernel into RAM ONLY, writes NOTHING
```
- If it boots and `/data` decrypts and everything works for a while -> the kernel is good.
- If it hangs / bootloops -> just **hold Power ~10 s** to reboot back into the
  untouched stock kernel. No partition was written, so nothing is damaged.

### 2. Only AFTER it is proven stable in RAM, make it permanent
Prefer the **AnyKernel3 zip** (replaces only the kernel inside stock `boot`,
keeps the stock ramdisk, does not touch vbmeta). Flashing a full `boot.img`
directly is riskier (ramdisk mismatch) and is not recommended for this device:
```bash
# in recovery / via the AnyKernel3 zip (recommended)
# — or, at your own risk, permanent boot flash:
# fastboot flash boot boot.img
```

> ⚠️ **Do NOT** `fastboot flash boot` an unverified kernel. That is exactly what
> corrupted `/data` before. RAM-boot (`fastboot boot`) first, every time.

## Where to make kernel edits later
- tiro config: `kernel/nubia/sm8650/arch/arm64/configs/oem/boards/tiro_diff.config`
  and platform `.../oem/pineapple_diff.config`
- source/drivers: `kernel/nubia/sm8650/...`
- device-tree overlays: `kernel/nubia/sm8650-devicetrees/qcom/tiro/`
- vendor kernel modules: `kernel/nubia/sm8650-modules/qcom/opensource/...`

## Display panel note
tiro panel = **BF068_RM692H0** (6.8" OLED, FHD+ 1116x2480, command mode, DSC),
discrete **60/120 Hz** only, no qsync/VRR. Adding 30/48/90 Hz needs vendor
register command sequences not present in the tree, so it's intentionally left out.

## Repos pulled (branch lineage-23.2)
| Path | Repo (nubia-sm8650-devs/...) |
|------|------|
| device/nubia/tiro | android_device_nubia_tiro |
| device/nubia/sm8650-common | android_device_nubia_sm8650-common |
| kernel/nubia/sm8650 | android_kernel_nubia_sm8650 |
| kernel/nubia/sm8650-devicetrees | android_kernel_nubia_sm8650-devicetrees |
| kernel/nubia/sm8650-modules | android_kernel_nubia_sm8650-modules |
| vendor/nubia/tiro | proprietary_vendor_nubia_tiro |
| vendor/nubia/sm8650-common | proprietary_vendor_nubia_sm8650-common |
