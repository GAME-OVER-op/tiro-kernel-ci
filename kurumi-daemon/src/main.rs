// =====================================================================
// Kurumi kernel userspace daemon (RedMagic 9 Pro, SM8650 / pineapple)
//
// Replaces the old shell `kurumi_battery`. Pure std (no external crates) so it
// builds to a fully-static aarch64 musl binary that runs on Android bionic.
//
// It writes ONLY to /sys and /proc -> fully reversible, no partition writes.
// Screen state is read from the tiny kernel sysfs bridge
// /sys/kernel/kurumi_screen/* when the kernel supports CONFIG_KURUMI_SCREEN_STATE.
// No logging (settings are just applied).
//
// Behaviour:
//   Once at start (after a short wait so vendor thermal services are up):
//     - disable_thermal_services(): faithful port of mora's 6-stage burn-mode
//       (stop services -> setprop -> pkill survivors -> zone mode=disabled ->
//        cooling cur_state=0 -> unbind userspace LMh). Battery zone 74 untouched.
//     - core_ctl on the big clusters (cpu2/cpu5/cpu7): allow core sleep.
//     - cpufreq floor/ceiling pinned per cluster to the true HW min/max OPP
//       (undo powerHAL/perfd raising scaling_min above the hardware minimum).
//     - vm.max_map_count = 1048576 (headroom for Wine/Winlator emulators).
//     - apply_surfaceflinger(): move every surfaceflinger thread from cpuset
//       system-background ("0-1,5-6" on this ROM) to foreground ("0-7"), and
//       raise the Adreno idle_timer from 80 to 120 ms. Immediate effect, lasts
//       until reboot, nothing restarted.
//     - apply_io_profile(): UFS + block read-ahead profile.
//     - apply_wifi_sleep_profile(): Android Wi-Fi sleep knobs plus WLAN direct
//       wakeup policy (eco/balance = delayed push, full = soft push).
//   Event-driven:
//     - touch-boost: block-read /dev/input/event* in threads (~0 CPU idle);
//       on input, pulse /proc/sys/walt/sched_user_hint (auto-decays), debounced.
//   Periodic:
//     - WALT + VM tunables: burst every 60s for the first 20 min (WALT governor
//       comes up late), then re-assert every 3h (idempotent).
// =====================================================================

use std::fs::{self, File};
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

// ---- thermal zones (exact IDs from the device / mora reference) ----
const CPU_ZONE_IDS: &[u32] = &[
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 25, 26, 27, 28, 29,
];
const GPU_ZONE_IDS: &[u32] = &[41, 42, 43, 44, 45, 46, 47, 48];

// ---- core_ctl: first CPU of each BIG cluster. Topology is 2+3+2+1:
//      cpu0-1 (little, left alone) | cpu2-4 | cpu5-6 | cpu7. core_ctl nodes live
//      only on a cluster's first cpu -> cpu2, cpu5, cpu7. ----
const CORE_CTL_CPUS: &[u32] = &[2, 5, 7];

// ---- touch-boost ----
const SCHED_USER_HINT: &str = "/proc/sys/walt/sched_user_hint";
const TOUCH_HINT_VALUE: &str = "500";
const TOUCH_DEBOUNCE_MS: u64 = 400;

// ---- timing ----
const BOOT_WAIT_SECS: u64 = 90;
const BURST_WINDOW_SECS: u64 = 20 * 60;
const BURST_INTERVAL_SECS: u64 = 60;
const STEADY_TICK_SECS: u64 = 3600;
const WALT_STEADY_SECS: u64 = 3 * 3600;

// ---- Kurumi kernel screen-state bridge ----
const KURUMI_SCREEN_STATE: &str = "/sys/kernel/kurumi_screen/state";
const KURUMI_SCREEN_SEQ: &str = "/sys/kernel/kurumi_screen/seq";
const KURUMI_SCREEN_POLL_MS: &str = "/sys/kernel/kurumi_screen/poll_ms";
const SCREEN_OFF_DEBOUNCE_SECS: u64 = 30;
const SCREEN_ON_DEFAULT_POLL_MS: u64 = 60_000;
const SCREEN_OFF_DEFAULT_POLL_MS: u64 = 30_000;
const SCREEN_POLL_MIN_MS: u64 = 5_000;
const SCREEN_POLL_MAX_MS: u64 = 300_000;

// Conservative temporary fallback while the panel is off.  It is intentionally
// runtime-only: chosen flash profile is restored immediately when the screen
// turns on again.
const SCREEN_OFF_CPUFREQ_LIMITS: &[(u32, &str, &str)] = &[
    (0, "364800", "1812480"),
    (2, "499200", "2204160"),
    (5, "499200", "1182720"),
    (7, "480000", "1320960"),
];
const SCREEN_OFF_UFS_CLKGATE: &str = "1";
const SCREEN_OFF_UFS_CLKSCALE: &str = "1";
const SCREEN_OFF_READ_AHEAD_KB: &str = "128";

// ---------- sysfs helpers ----------

fn write_val<P: AsRef<Path>>(path: P, val: &str) -> bool {
    let p = path.as_ref();
    if !p.exists() {
        return false;
    }
    if fs::write(p, val).is_ok() {
        return true;
    }
    // Retry after forcing the node writable (some /sys nodes are 0444/0644).
    if let Ok(md) = fs::metadata(p) {
        let mut perm = md.permissions();
        perm.set_mode(0o644);
        let _ = fs::set_permissions(p, perm);
    }
    fs::write(p, val).is_ok()
}

// Idempotent: only writes when the current value differs (avoids needless churn
// on periodic 3h WALT/VM re-assertions and profile restores).
fn write_if_diff<P: AsRef<Path>>(path: P, val: &str) -> bool {
    let p = path.as_ref();
    if !p.exists() {
        return false;
    }
    if let Ok(cur) = fs::read_to_string(p) {
        if cur.trim() == val {
            return false;
        }
    }
    write_val(p, val)
}

fn read_trim<P: AsRef<Path>>(path: P) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

fn read_u64<P: AsRef<Path>>(path: P) -> Option<u64> {
    read_trim(path)?.parse().ok()
}

fn run_cmd(cmd: &str, args: &[&str]) {
    let _ = Command::new(cmd).args(args).output();
}

fn put_global_setting(key: &str, val: &str) {
    run_cmd("settings", &["put", "global", key, val]);
}

// ---------- one-time: thermal burn-mode (faithful port of mora) ----------

const STOP_SERVICES: &[&str] = &[
    "android.thermal-hal",
    "vendor.thermal-engine",
    "vendor.thermal_manager",
    "vendor.thermal-manager",
    "vendor.thermal-hal-2-0",
    "vendor.thermal-symlinks",
    "thermal_mnt_hal_service",
    "thermal",
    "mi_thermald",
    "thermald",
    "thermalloadalgod",
    "thermalservice",
    "sec-thermal-1-0",
    "debug_pid.sec-thermal-1-0",
    "thermal-engine",
    "vendor.thermal-hal-1-0",
    "vendor-thermal-1-0",
    "thermal-hal",
    "vendor.qti.hardware.perf2-hal-service",
    "qti-msdaemon_vendor-0",
    "qti-msdaemon_vendor-1",
    "qti-ssdaemon_vendor",
];

const SETPROP_STOPPED: &[(&str, &str)] = &[
    ("init.svc.thermal", "stopped"),
    ("init.svc.thermal-managers", "stopped"),
    ("init.svc.thermal_manager", "stopped"),
    ("init.svc.thermal_mnt_hal_service", "stopped"),
    ("init.svc.thermal-engine", "stopped"),
    ("init.svc.mi-thermald", "stopped"),
    ("init.svc.thermalloadalgod", "stopped"),
    ("init.svc.thermalservice", "stopped"),
    ("init.svc.thermal-hal", "stopped"),
    ("init.svc.vendor.thermal-symlinks", ""),
    ("init.svc.android.thermal-hal", "stopped"),
    ("init.svc.vendor.thermal-hal", "stopped"),
    ("init.svc.thermal-manager", "stopped"),
    ("init.svc.vendor-thermal-hal-1-0", "stopped"),
    ("init.svc.vendor.thermal-hal-1-0", "stopped"),
    ("init.svc.vendor.thermal-hal-2-0.mtk", "stopped"),
    ("init.svc.vendor.thermal-hal-2-0", "stopped"),
];

const KILL_PATTERNS: &[&str] = &[
    "thermal-service.qti",
    "android.hardware.thermal",
    "thermal-engine",
    "thermald",
];

fn disable_thermal_services() {
    // 1) stop known thermal init services
    for svc in STOP_SERVICES {
        let _ = Command::new("stop").arg(svc).output();
        thread::sleep(Duration::from_millis(50));
    }
    // 2) mark them stopped so init does not restart them
    for (prop, val) in SETPROP_STOPPED {
        let _ = Command::new("setprop").arg(prop).arg(val).output();
        thread::sleep(Duration::from_millis(50));
    }
    // 3) hard-kill survivors that keep applying mitigations
    for pat in KILL_PATTERNS {
        let _ = Command::new("pkill").arg("-f").arg(pat).output();
        thread::sleep(Duration::from_millis(50));
    }
    // 4) disable in-kernel thermal on CPU/GPU zones (battery/BCL left untouched)
    for &id in CPU_ZONE_IDS.iter().chain(GPU_ZONE_IDS.iter()) {
        let _ = fs::write(
            format!("/sys/class/thermal/thermal_zone{}/mode", id),
            "disabled",
        );
    }
    // 5) reset already-engaged CPU/GPU cooling devices back to 0
    if let Ok(entries) = fs::read_dir("/sys/class/thermal") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.starts_with("cooling_device") {
                continue;
            }
            let p = entry.path();
            let ty = fs::read_to_string(p.join("type")).unwrap_or_default();
            let ty = ty.trim();
            if ty.starts_with("cpufreq-")
                || ty.starts_with("cpu-cluster")
                || ty.starts_with("thermal-cluster")
                || ty == "gpu"
            {
                let _ = fs::write(p.join("cur_state"), "0");
            }
        }
    }
    // 6) unbind the userspace LMh driver (real enforcer is CPUCP firmware)
    let _ = fs::write(
        "/sys/bus/platform/drivers/msm_lmh_dcvs/unbind",
        "soc:qcom,limits-dcvs",
    );
}

// ---------- one-time: core_ctl + memory ----------

fn apply_core_ctl() {
    for &c in CORE_CTL_CPUS {
        let base = format!("/sys/devices/system/cpu/cpu{}/core_ctl", c);
        if !Path::new(&base).exists() {
            continue;
        }
        write_val(format!("{}/enable", base), "1");
        write_val(format!("{}/min_cpus", base), "0");
        write_val(format!("{}/offline_delay_ms", base), "50");
        write_val(format!("{}/busy_up_thres", base), "60");
        write_val(format!("{}/busy_down_thres", base), "30");
    }
}

fn apply_memory() {
    // Emulator headroom (Wine/Winlator). Default 65530 is a common crash source.
    write_if_diff("/proc/sys/vm/max_map_count", "1048576");
}

// ---------- one-time: UFS + block read-ahead profile ----------
// The daemon is launched by init.kurumi.rc only after sys.boot_completed=1.
// main() then sleeps BOOT_WAIT_SECS (90s). This means these I/O tunables are
// applied only once, after boot_completed + 90s, after vendor init has settled.
// No screen polling / idle loop is needed.
//
// auto_hibern8 is deliberately NOT touched: on this device it reads blank and
// rejects writes. clkgate_enable and clkscale_enable were verified writable.
//
// Profile policy:
//   eco:     let UFS save power, low read-ahead.
//   balance: stock-like post-boot policy.
//   full:    keep UFS clock gating enabled so it can sleep while idle/screen-off,
//            but disable clock scaling for lower I/O latency under load.

#[cfg(feature = "eco")]
const IO_UFS_CLKGATE: &str = "1";
#[cfg(feature = "eco")]
const IO_UFS_CLKSCALE: &str = "1";
#[cfg(feature = "eco")]
const IO_READ_AHEAD_KB: &str = "128";

#[cfg(feature = "balance")]
const IO_UFS_CLKGATE: &str = "1";
#[cfg(feature = "balance")]
const IO_UFS_CLKSCALE: &str = "1";
#[cfg(feature = "balance")]
const IO_READ_AHEAD_KB: &str = "512";

#[cfg(feature = "full")]
const IO_UFS_CLKGATE: &str = "1";
#[cfg(feature = "full")]
const IO_UFS_CLKSCALE: &str = "0";
#[cfg(feature = "full")]
const IO_READ_AHEAD_KB: &str = "2048";

const UFS_BASES: &[&str] = &[
    "/sys/devices/platform/soc/1d84000.ufshc",
    "/sys/bus/platform/devices/1d84000.ufshc",
];

fn apply_ufs_values(clkgate: &str, clkscale: &str) {
    // The two UFS paths are aliases on this device. Write the first existing
    // one only to avoid duplicate work.
    for base in UFS_BASES {
        let base = Path::new(base);
        if !base.exists() {
            continue;
        }
        write_if_diff(base.join("clkgate_enable"), clkgate);
        write_if_diff(base.join("clkscale_enable"), clkscale);
        break;
    }
}

fn apply_ufs_policy() {
    apply_ufs_values(IO_UFS_CLKGATE, IO_UFS_CLKSCALE);
}

fn is_target_block_device(name: &str) -> bool {
    name.starts_with("dm-")
        || name.starts_with("sd")
        || name.starts_with("mmcblk")
        || name.starts_with("nvme")
}

fn apply_read_ahead_value(value: &str) {
    if let Ok(entries) = fs::read_dir("/sys/block") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !is_target_block_device(&name) {
                continue;
            }
            write_if_diff(entry.path().join("queue").join("read_ahead_kb"), value);
        }
    }
}

fn apply_read_ahead() {
    apply_read_ahead_value(IO_READ_AHEAD_KB);
}

fn apply_io_profile() {
    apply_ufs_policy();
    apply_read_ahead();
}

// ---------- one-time: Wi-Fi sleep / push policy ----------
// Real sleep-probe data from this device pointed at WLAN/qcom_rx_wakelock and
// Google/network location wakeups, not UFS or the Rust loop. We keep Wi-Fi ON,
// but remove background scan / forced-performance knobs and choose how strongly
// WLAN may wake the AP from suspend.
//
// Applied once after boot_completed + 90s, together with the other profile
// tunables. There is deliberately NO screen polling and NO periodic Wi-Fi loop.
//
// Policy:
//   eco/balance: delayed push. Disable direct WLAN endpoint wakeup only; do not
//                disable the PCIe parent chain, so Wi-Fi is not killed. Pushes
//                may arrive during Doze maintenance windows / next wake.
//   full:        soft push. Keep/re-enable direct WLAN wakeup so notifications
//                are close to stock, but still clear scan/perf knobs.

#[cfg(any(feature = "eco", feature = "balance"))]
const WIFI_DIRECT_WAKEUP: &str = "disabled";
#[cfg(feature = "full")]
const WIFI_DIRECT_WAKEUP: &str = "enabled";

const WIFI_NETDEVS: &[&str] = &["wlan0", "wifi-aware0", "wlan1"];

fn apply_android_wifi_sleep_knobs() {
    // Keep Wi-Fi connected. These only reduce extra background radio activity.
    put_global_setting("mobile_data_always_on", "0");
    put_global_setting("wifi_scan_always_enabled", "0");
    put_global_setting("ble_scan_always_enabled", "0");
    put_global_setting("wifi_wakeup_enabled", "0");
    put_global_setting("wifi_networks_available_notification_on", "0");
    put_global_setting("network_recommendations_enabled", "0");

    // AOSP Wi-Fi shell knobs. Missing/unsupported commands are harmless.
    run_cmd("cmd", &["wifi", "set-scan-always-available", "disabled"]);
    run_cmd("cmd", &["wifi", "set-verbose-logging", "disabled"]);
    run_cmd("cmd", &["wifi", "force-hi-perf-mode", "disabled"]);
    run_cmd("cmd", &["wifi", "force-low-latency-mode", "disabled"]);
}

fn wlan_direct_wakeup_nodes() -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    for dev in WIFI_NETDEVS {
        let link = Path::new("/sys/class/net").join(dev).join("device");
        if !link.exists() {
            continue;
        }
        let target = fs::canonicalize(&link).unwrap_or(link);
        let node = target.join("power").join("wakeup");
        if !node.exists() {
            continue;
        }
        if !out.iter().any(|p| p == &node) {
            out.push(node);
        }
    }
    out
}

fn apply_wlan_direct_wakeup_policy() {
    for node in wlan_direct_wakeup_nodes() {
        write_if_diff(node, WIFI_DIRECT_WAKEUP);
    }
}

fn apply_wifi_sleep_profile() {
    apply_android_wifi_sleep_knobs();
    apply_wlan_direct_wakeup_policy();
}

// ---------- one-time: SurfaceFlinger placement + GPU idle timer ----------
// Measured on this device (NX769J / RedMagic 9 Pro): surfaceflinger sits in
// cpuset system-background, which this ROM pins to "0-1,5-6". It therefore
// never gets the mid cluster (cpu2-4) nor the prime core (cpu7), while
// cpuset foreground is "0-7". Composition is latency-critical and bursty
// (~8.33ms budget at 120Hz), so the same work on slower cores simply shows up
// as a higher CPU percentage. Moving it to foreground gives it all 8 cores.
//
// kgsl idle_timer 80 -> 120 ms: with continuous client composition (a PiP
// window drags every layer below it into GPU composition) the 80ms timer makes
// the GPU drop to its lowest OPP between bursts and ramp back up again.
//
// Both writes take effect immediately and last until reboot. Nothing is
// restarted. Deliberately one-time only, NOT part of any periodic re-check:
// cpuset membership is per-thread and only needs setting once per SF lifetime.

fn sf_pid() -> Option<u32> {
    // /proc scan instead of shelling out to `pidof`.
    for e in fs::read_dir("/proc").ok()?.flatten() {
        let pid: u32 = match e.file_name().to_string_lossy().parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        if let Ok(cmd) = fs::read_to_string(format!("/proc/{}/cmdline", pid)) {
            if cmd.trim_end_matches('\0').ends_with("surfaceflinger") {
                return Some(pid);
            }
        }
    }
    None
}

fn apply_surfaceflinger() {
    // cpuset: every thread must be moved individually, the group is not
    // inherited by already-running threads.
    if let Some(pid) = sf_pid() {
        if let Ok(tasks) = fs::read_dir(format!("/proc/{}/task", pid)) {
            for t in tasks.flatten() {
                let tid = t.file_name().to_string_lossy().to_string();
                let _ = fs::write("/dev/cpuset/foreground/tasks", &tid);
            }
        }
    }

    write_if_diff("/sys/class/kgsl/kgsl-3d0/idle_timer", "120");
}

// ---------- one-time + periodic: cpufreq floor / ceiling ----------
// On init powerHAL/perfd raises scaling_min_freq one or two OPP steps above the
// true hardware minimum, which wastes idle power. mora pins each cluster back to
// its lowest / highest AVAILABLE OPP. Values are hard-coded (KHz) from THIS
// device's cpufreq tables (RedMagic 9 Pro, SM8650 pineapple); see each policy's
// scaling_available_frequencies:
//   policy0 (cpu0-1, little): 364800 .. 2265600
//   policy2 (cpu2-4, gold):   499200 .. 3148800
//   policy5 (cpu5-6, gold):   499200 .. 2956800
//   policy7 (cpu7, prime):    480000 .. 3302400
// (min, max) per first-cpu policy id. If a table ever changes these become
// no-ops that just clamp to whatever the node accepts -- never above HW max.
// Profile is chosen at BUILD time via a cargo feature (eco|balance|full). CI
// compiles one binary per profile from THIS single source and the flasher
// installs the one the user picks; ONLY this table differs between them.
//   little = policy0 (cpu0-1), mid = policy2 (cpu2-4),
//   big    = policy5 (cpu5-6), prime = policy7 (cpu7).
// full == true HW min/max on every cluster.
#[cfg(feature = "full")]
const CPUFREQ_LIMITS: &[(u32, &str, &str)] = &[
    (0, "364800", "2265600"),
    (2, "499200", "3148800"),
    (5, "499200", "2956800"),
    (7, "480000", "3302400"),
];

// eco: little ceiling ~80%, mid ~70%, big+prime ~40% of HW max (floor = HW min).
#[cfg(feature = "eco")]
const CPUFREQ_LIMITS: &[(u32, &str, &str)] = &[
    (0, "364800", "1812480"),
    (2, "499200", "2204160"),
    (5, "499200", "1182720"),
    (7, "480000", "1320960"),
];

// balance: little untouched, mid ~80%, big+prime ~70% of HW max.
#[cfg(feature = "balance")]
const CPUFREQ_LIMITS: &[(u32, &str, &str)] = &[
    (0, "364800", "2265600"),
    (2, "499200", "2519040"),
    (5, "499200", "2069760"),
    (7, "480000", "2311680"),
];

// Refuse to build a daemon with no profile selected or with multiple profiles.
#[cfg(not(any(feature = "eco", feature = "balance", feature = "full")))]
compile_error!("select exactly one profile feature: eco | balance | full");

#[cfg(any(
    all(feature = "eco", feature = "balance"),
    all(feature = "eco", feature = "full"),
    all(feature = "balance", feature = "full")
))]
compile_error!("select exactly one profile feature: eco | balance | full");

fn apply_cpufreq_limit_table(limits: &[(u32, &str, &str)]) {
    for &(policy, min, max) in limits {
        let base = format!("/sys/devices/system/cpu/cpufreq/policy{}", policy);
        if !Path::new(&base).exists() {
            continue;
        }
        // Raise the ceiling before lowering the floor so scaling_min can never
        // transiently exceed scaling_max (kernel rejects that write).
        write_if_diff(format!("{}/scaling_max_freq", base), max);
        write_if_diff(format!("{}/scaling_min_freq", base), min);
    }
}

fn apply_cpufreq_limits() {
    apply_cpufreq_limit_table(CPUFREQ_LIMITS);
}

// ---------- periodic: WALT cpufreq smoothing + VM ----------

fn apply_walt_vm() {
    if let Ok(entries) = fs::read_dir("/sys/devices/system/cpu/cpufreq") {
        for entry in entries.flatten() {
            let walt = entry.path().join("walt");
            if !walt.is_dir() {
                continue;
            }
            write_if_diff(walt.join("up_rate_limit_us"), "1000");
            write_if_diff(walt.join("down_rate_limit_us"), "2000");
            write_if_diff(walt.join("hispeed_load"), "90");
        }
    }
    write_if_diff("/proc/sys/vm/dirty_writeback_centisecs", "1500");
    write_if_diff("/proc/sys/vm/stat_interval", "10");
    write_if_diff("/sys/kernel/mm/lru_gen/min_ttl_ms", "1000");
}

// ---------- kernel-assisted screen-off fallback ----------

#[derive(Clone, Copy, PartialEq, Eq)]
enum ScreenState {
    On,
    Off,
    Doze,
    Unknown,
}

fn read_screen_state() -> ScreenState {
    match read_trim(KURUMI_SCREEN_STATE).as_deref() {
        Some("on") => ScreenState::On,
        Some("off") => ScreenState::Off,
        Some("doze") => ScreenState::Doze,
        _ => ScreenState::Unknown,
    }
}

fn read_screen_poll_ms(state: ScreenState) -> u64 {
    let fallback = match state {
        ScreenState::Off => SCREEN_OFF_DEFAULT_POLL_MS,
        _ => SCREEN_ON_DEFAULT_POLL_MS,
    };
    read_u64(KURUMI_SCREEN_POLL_MS)
        .unwrap_or(fallback)
        .clamp(SCREEN_POLL_MIN_MS, SCREEN_POLL_MAX_MS)
}

fn apply_screen_off_fallback() {
    apply_core_ctl();
    apply_cpufreq_limit_table(SCREEN_OFF_CPUFREQ_LIMITS);
    apply_ufs_values(SCREEN_OFF_UFS_CLKGATE, SCREEN_OFF_UFS_CLKSCALE);
    apply_read_ahead_value(SCREEN_OFF_READ_AHEAD_KB);
}

fn restore_selected_profile_after_screen_on() {
    apply_core_ctl();
    apply_cpufreq_limits();
    apply_io_profile();
    apply_walt_vm();
}

fn screen_state_loop(screen_active: Arc<AtomicBool>) {
    let mut last_seq: Option<u64> = None;
    let mut fallback_applied = false;

    loop {
        if !Path::new(KURUMI_SCREEN_STATE).exists() {
            screen_active.store(true, Ordering::Relaxed);
            if fallback_applied {
                restore_selected_profile_after_screen_on();
                fallback_applied = false;
            }
            thread::sleep(Duration::from_millis(SCREEN_ON_DEFAULT_POLL_MS));
            continue;
        }

        let state = read_screen_state();
        let seq = read_u64(KURUMI_SCREEN_SEQ).unwrap_or(0);
        let changed = last_seq.map_or(true, |old| old != seq);

        match state {
            ScreenState::Off => screen_active.store(false, Ordering::Relaxed),
            ScreenState::On | ScreenState::Doze | ScreenState::Unknown => {
                screen_active.store(true, Ordering::Relaxed)
            }
        }

        if changed {
            match state {
                ScreenState::Off => {
                    // Debounce: ignore quick lock/unlock or transient blank events.
                    thread::sleep(Duration::from_secs(SCREEN_OFF_DEBOUNCE_SECS));
                    if read_screen_state() == ScreenState::Off {
                        screen_active.store(false, Ordering::Relaxed);
                        apply_screen_off_fallback();
                        fallback_applied = true;
                    } else if fallback_applied {
                        screen_active.store(true, Ordering::Relaxed);
                        restore_selected_profile_after_screen_on();
                        fallback_applied = false;
                    }
                }
                ScreenState::On | ScreenState::Doze => {
                    screen_active.store(true, Ordering::Relaxed);
                    if fallback_applied {
                        restore_selected_profile_after_screen_on();
                        fallback_applied = false;
                    }
                }
                ScreenState::Unknown => {
                    screen_active.store(true, Ordering::Relaxed);
                    if fallback_applied {
                        restore_selected_profile_after_screen_on();
                        fallback_applied = false;
                    }
                }
            }
            last_seq = Some(seq);
        }

        thread::sleep(Duration::from_millis(read_screen_poll_ms(state)));
    }
}

fn spawn_screen_state_thread(screen_active: Arc<AtomicBool>) {
    thread::spawn(move || screen_state_loop(screen_active));
}

// ---------- event-driven: touch-boost ----------

fn maybe_pulse(last: &Arc<Mutex<Instant>>, screen_active: &Arc<AtomicBool>) {
    if !screen_active.load(Ordering::Relaxed) {
        return;
    }
    if let Ok(mut g) = last.lock() {
        if g.elapsed() >= Duration::from_millis(TOUCH_DEBOUNCE_MS) {
            write_val(SCHED_USER_HINT, TOUCH_HINT_VALUE);
            *g = Instant::now();
        }
    }
}

// One blocking reader per input device. The struct input_event on 64-bit is 24
// bytes: { __kernel_ulong_t sec; __kernel_ulong_t usec; __u16 type; __u16 code;
// __s32 value }. We only need `type` (offset 16). EV_KEY=1 / EV_ABS=3 => touch.
fn touch_loop(path: std::path::PathBuf, last: Arc<Mutex<Instant>>, screen_active: Arc<AtomicBool>) {
    let mut file = match File::open(&path) {
        Ok(f) => f,
        Err(_) => return,
    };
    let mut buf = [0u8; 24];
    loop {
        match file.read_exact(&mut buf) {
            Ok(()) => {
                let etype = u16::from_ne_bytes([buf[16], buf[17]]);
                if etype == 1 || etype == 3 {
                    maybe_pulse(&last, &screen_active);
                }
            }
            Err(_) => {
                // Device hiccup/hotplug: back off and try to reopen; give up if gone.
                thread::sleep(Duration::from_millis(500));
                match File::open(&path) {
                    Ok(f) => file = f,
                    Err(_) => return,
                }
            }
        }
    }
}

fn spawn_touch_threads(last: Arc<Mutex<Instant>>, screen_active: Arc<AtomicBool>) {
    if let Ok(entries) = fs::read_dir("/dev/input") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.starts_with("event") {
                continue;
            }
            let path = entry.path();
            let last = Arc::clone(&last);
            let screen_active = Arc::clone(&screen_active);
            thread::spawn(move || touch_loop(path, last, screen_active));
        }
    }
}

// ---------- main ----------

fn main() {
    // Touch-boost threads start immediately; they block on input (~0 CPU idle).
    let last_touch = Arc::new(Mutex::new(Instant::now() - Duration::from_secs(3600)));
    let screen_active = Arc::new(AtomicBool::new(true));
    spawn_touch_threads(Arc::clone(&last_touch), Arc::clone(&screen_active));

    // One-time setup, after vendor thermal services have come up so `stop` bites.
    thread::sleep(Duration::from_secs(BOOT_WAIT_SECS));
    disable_thermal_services();
    apply_core_ctl();
    apply_cpufreq_limits();
    apply_memory();
    apply_surfaceflinger();
    apply_io_profile();
    apply_wifi_sleep_profile();
    spawn_screen_state_thread(Arc::clone(&screen_active));

    // Burst: re-assert WALT/VM every 60s for the first 20 min (WALT governor is
    // late; idempotent writes settle once its sysfs dir appears).
    let burst_end = Instant::now() + Duration::from_secs(BURST_WINDOW_SECS);
    loop {
        apply_walt_vm();
        if Instant::now() >= burst_end {
            break;
        }
        thread::sleep(Duration::from_secs(BURST_INTERVAL_SECS));
    }

    // Steady state: hourly tick. Only WALT/VM is re-asserted every 3h.
    // Thermal disabling is intentionally one-shot at boot after BOOT_WAIT_SECS.
    let mut walt_acc: u64 = 0;
    loop {
        thread::sleep(Duration::from_secs(STEADY_TICK_SECS));
        walt_acc += STEADY_TICK_SECS;
        if walt_acc >= WALT_STEADY_SECS {
            apply_walt_vm();
            walt_acc = 0;
        }
    }
}
