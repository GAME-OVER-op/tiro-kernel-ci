# Tiro Pineapple Optimization Package 1–7

This document describes the first Qualcomm Pineapple optimization package carried by the Kurumi kernel CI for Nubia / RedMagic `tiro` (NX769J / NX769S, SM8650, Linux 6.1).

The package intentionally backports only targeted ideas from the newer Qualcomm 6.6 WALT/UFS implementation. It does **not** merge the 6.6 scheduler, EEVDF, memory-management core, or the complete 6.6 UFS driver into Nubia 6.1.

## 1. Block writeback throttling

`CONFIG_BLK_WBT` is intentionally **not enabled** on Tiro. In this Linux 6.1 tree it changes the layout of `struct request`, which is unsafe to mix with the ROM's existing prebuilt vendor/vendor_dlkm modules. CI fails if `CONFIG_BLK_WBT=y` appears in the final Image.

## 2. Disable per-VMA lock statistics

Per-VMA locking itself is kept. Only the optional statistics counters are removed:

```text
CONFIG_PER_VMA_LOCK=y
# CONFIG_PER_VMA_LOCK_STATS is not set
```

This removes development-only statistics bookkeeping from the page-fault path without disabling per-VMA locking.

CI fails if the final Image still contains `CONFIG_PER_VMA_LOCK_STATS=y`.

## 3. Asynchronous SCSI scan

The GKI Image requests:

```text
CONFIG_SCSI_SCAN_ASYNC=y
```

UFS is exposed through the SCSI layer, so asynchronous scanning can reduce serial device-discovery work during initialization.

CI extracts the final built Image config and verifies the option is active.

Kleaf note: the integration writes this symbol immediately after `CONFIG_BLK_DEV_SD=y`, matching `savedefconfig` canonical ordering. This avoids the strict `common/arch/arm64/configs/gki_defconfig` mismatch check used by the standalone Android 14 Kleaf build.

## 4. Qualcomm-style WALT storage IRQ load balancing

Nubia 6.1 already uses `sched_set_boost(STORAGE_BOOST)` from `ufs-qcom` during heavy storage activity. The new backport extends that existing mechanism instead of replacing it.

The integration adds:

- `kernel/sched/walt/walt_storage_lb.c`;
- an enforced high-IRQ CPU mask in WALT;
- reference-counted set/unset APIs for high-IRQ CPUs;
- UFS ESI/MSI affinity-mask tracking;
- task migration away from CPUs carrying heavy storage IRQ work while `STORAGE_BOOST` is active;
- a Pineapple destination mask that excludes the minimum-capacity cluster for storage-load migration;
- a conservative 3 ms balance interval to avoid continuous migration attempts.

The feature is enabled by default and can be disabled at runtime through the `sched-walt` module parameter:

```text
kurumi_storage_lb=1
```

On-device discovery example:

```sh
find /sys/module -path '*/parameters/kurumi_storage_lb' -print
```

Then, as root:

```sh
echo 0 > /sys/module/sched_walt/parameters/kurumi_storage_lb
echo 1 > /sys/module/sched_walt/parameters/kurumi_storage_lb
```

The exact module directory name is kernel-generated; use `find` if it differs.

## 5. Runtime UFS boost thresholds

The original compile-time Qualcomm UFS defaults are preserved at boot, but become runtime-adjustable fields in the UFS host:

- minimum request threshold;
- maximum request threshold;
- boost monitor interval in milliseconds.

The new sysfs attributes are:

```text
boost_min_threshold
boost_max_threshold
boost_monitor_timer_ms
```

Defaults are initialized from the existing Nubia/Qualcomm constants (`NUM_REQS_LOW_THRESH`, `NUM_REQS_HIGH_THRESH`, and `UFS_QCOM_LOAD_MON_DLY_MS`). No more aggressive value is forced at boot.

Safety rules:

- minimum must remain below maximum;
- maximum must remain above minimum;
- monitor interval is restricted to 5–1000 ms;
- writes require `CAP_SYS_ADMIN`.

Find the live attributes with:

```sh
find /sys -name boost_min_threshold -o -name boost_max_threshold -o -name boost_monitor_timer_ms 2>/dev/null
```

## 6. Pineapple boost-to-next-cluster switch

The 4-cluster Nubia WALT placement path already contains behavior close to the newer Qualcomm Pineapple policy. The integration keeps the current enabled behavior but wraps it in an explicit runtime switch:

```text
kurumi_boost_to_next_cluster=1
```

This allows a boosted/latency-sensitive fair task to consider the next performance cluster instead of being constrained to the weakest candidate range.

It can be disabled for A/B testing without rebuilding the kernel:

```sh
echo 0 > /sys/module/sched_walt/parameters/kurumi_boost_to_next_cluster
```

## 7. Pineapple Silver RT spread switch

Tiro's existing 4-cluster WALT RT path already broadens the first-cluster search range. The integration preserves that behavior by default and exposes it as:

```text
kurumi_silver_rt_spread=1
```

This makes the behavior reversible at runtime while retaining the stock-like enabled default:

```sh
echo 0 > /sys/module/sched_walt/parameters/kurumi_silver_rt_spread
```

## Files changed at CI integration time

The source integration script modifies the freshly cloned Nubia kernel tree before the build. Important paths are:

```text
kernel/sched/walt/Makefile
kernel/sched/walt/walt.h
kernel/sched/walt/walt.c
kernel/sched/walt/walt_lb.c
kernel/sched/walt/walt_cfs.c
kernel/sched/walt/walt_rt.c
kernel/sched/walt/walt_storage_lb.c   (new)
include/linux/sched/walt.h
drivers/ufs/host/ufs-qcom.h
drivers/ufs/host/ufs-qcom.c
```

Base GKI power settings are applied by `scripts/kurumi_integrate_power_config.sh`. The standalone-only safe subset for items 2 and 3 is applied afterwards by `scripts/kurumi_integrate_tiro_safe_2_3.sh`; it deliberately refuses to enable `CONFIG_BLK_WBT`.

## Current integration status

The Qualcomm 6.6 scheduler/UFS source backport for items 4-7 is still applied to the freshly cloned Nubia `msm-kernel` tree and compile-verified by CI. This keeps the experiment reproducible without silently changing the flash contract.

The flashable ZIP itself is deliberately **kernel-only**. It does not bundle or flash a complete `vendor_boot.img`.

### Boot compatibility status for items 1-3

The first combined test reached an early boot loop with both the normal boot-only path and the experimental full-vendor_boot path. The strongest compatibility hazard is `CONFIG_BLK_WBT`: in Linux 6.1 it conditionally adds `wbt_flags` to `struct request`, so enabling it changes a block-layer structure seen by vendor drivers. It therefore stays disabled.

The two config changes that do not alter this block-layer structure are restored for the standalone Kleaf build:

- keep `CONFIG_BLK_WBT` disabled;
- disable only `CONFIG_PER_VMA_LOCK_STATS` while preserving per-VMA locking;
- enable `CONFIG_SCSI_SCAN_ASYNC=y`;
- keep all previously proven Kurumi/GKI compatibility settings unchanged.

The standalone workflow verifies all three conditions from the config embedded in the final built Image.

## Flash contract

The installer uses the same proven path as before the full-image experiment:

```text
selected kernel
  -> replace kernel in boot
  -> preserve installed boot ramdisk

CUSTOM/STOCK GPU DTB
  -> read the device's currently installed vendor_boot
  -> replace only its DTB section
  -> repack that same image
  -> write it back
```

There is no Full/Compatible vendor_boot menu and no bundled `vendor_boot.img` payload.

The DTB-only `vendor_boot` handling remains because it predates this experiment and is the existing device-specific GPU-table mechanism. It does not install a foreign complete vendor_boot image.

## Runtime status of items 4-7

Items 4-7 live in rebuilt vendor modules (`sched-walt.ko` and `ufs_qcom.ko`). Because the safe flash ZIP does not replace those modules, the current kernel-only installer does **not** claim items 4-7 as active at runtime. They remain source-level experiments for later work.

## Files used by the experiment

```text
scripts/kurumi_integrate_tiro_optimizations.py
scripts/kurumi_verify_tiro_optimizations.py
```

The upstream Nubia repository is still fetched cleanly on every CI run; the experiment is applied only inside CI.

