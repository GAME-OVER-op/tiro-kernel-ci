# Kurumi Performance Guard / panic diagnostics

This repository now applies the guard to the kernel source that produces the
actual booted Image.

## Thermal policy

Kurumi leaves the Linux thermal framework and thermal zones enabled. Critical
trip handling, LMH/EPSS and non-performance safety devices remain available.
The common thermal path and the userspace `cooling_device*/cur_state` path clamp
the following performance cooling-device types to effective state `0`:

- CPU cpufreq, cluster, hotplug/isolation and thermal-pause devices;
- Adreno/KGSL devfreq and `gpu` devices;
- `display-fps`.

Cooling devices for battery/charging, BCL/PMIC, UFS, DDR, modem and WLAN are not
matched by the guard.

The Rust profile daemon therefore no longer stops/kills thermal services,
disables thermal zones, resets cooling devices, or unbinds LMH.

## CPU base minimum

Writes through the normal `scaling_min_freq` sysfs attribute validate normally
but the base cpufreq QoS request is kept at `policy->cpuinfo.min_freq`. This
removes the permanent vendor post-boot floor while preserving independent
kernel `freq_qos_request` clients, including WALT/input boosts.

The Rust daemon only applies profile maximum ceilings.

## Ramoops

Tiro's observed stock DT uses a 2 MiB ramoops region with all 2 MiB assigned to
pmsg. Kurumi changes the layout to:

- 1 MiB `record-size` for panic/oops dmesg;
- 512 KiB `console-size`;
- 512 KiB `pmsg-size`.

DT sources are patched only when the exact legacy Tiro 2-MiB-all-pmsg ramoops layout is present. In addition, `ram.c`
contains a narrowly-scoped fallback that only rewrites the exact legacy
2-MiB-all-pmsg layout. This matters for the kernel-only AnyKernel flow because
it deliberately preserves the phone's installed vendor_boot DTB.

## Crash-debug CI artifacts

Kernel/ROM workflows retain a separate crash-debug artifact containing as many
of the exact per-build files as Kleaf/Soong exposes: Image, boot images,
`vmlinux.gz`, `System.map`, `Module.symvers`, embedded final config, source
identity and SHA-256 hashes. Keep the artifact that corresponds to every kernel
you flash; it is required to symbolize a future EDL/minidump panic accurately.

## Manual persistent logger

`scripts/kurumi_device_panic_logger.sh` is a manual rooted-device diagnostic
tool. It is not installed or started by AnyKernel, so normal users get no extra
logging I/O.

Example:

```sh
sh kurumi_device_panic_logger.sh start
sh kurumi_device_panic_logger.sh status
# immediately after recovering from a panic/reboot:
sh kurumi_device_panic_logger.sh postpanic
sh kurumi_device_panic_logger.sh stop
```

It rotates Android logcat and telemetry, keeps a live dmesg stream, samples
CPU/GPU/thermal/PSI state, and writes a compact breadcrumb to `/dev/pmsg0` when
available.

## Expected on-device checks after flashing

With no temporary WALT/input boost active, each policy's base minimum should
return to its hardware minimum:

```sh
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  echo "$(basename "$p") hw=$(cat "$p/cpuinfo_min_freq") effective=$(cat "$p/scaling_min_freq")"
done
```

A short rise in `scaling_min_freq` during touch/input is expected and proves
that independent freq-QoS boosts still work.

Performance thermal cdevs should remain at zero even if userspace requests a
nonzero state:

```sh
for c in /sys/class/thermal/cooling_device*; do
  [ -e "$c/type" ] || continue
  t=$(cat "$c/type")
  case "$t" in
    *cpufreq*|*cpu-hotplug*|*cpu-isolate*|*pause-cpu*|*thermal-pause*|*cluster*|*kgsl*|gpu|display-fps)
      echo "$(basename "$c") $t state=$(cat "$c/cur_state")"
      ;;
  esac
done
```

After a real panic and reboot, check `/sys/fs/pstore` before cleaning logs.

## Safety boundary

This deliberately removes the normal Linux/userspace CPU/GPU/display software
thermal performance throttling path. It can materially increase sustained
temperature and power draw. Kurumi intentionally retains critical thermal
shutdown, hardware LMH/EPSS and battery/charging/BCL/PMIC/storage/modem safety
paths, but those remaining protections are not equivalent to stock thermal
policy.
