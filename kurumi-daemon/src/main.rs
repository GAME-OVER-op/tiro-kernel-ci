// =====================================================================
// Kurumi kernel userspace daemon (RedMagic 9 Pro, SM8650 / pineapple)
//
// Replaces the old shell `kurumi_battery`. Pure std (no external crates) so it
// builds to a fully-static aarch64 musl binary that runs on Android bionic.
//
// It writes profile tunables to /sys and /proc only, and stores optional
// read-only power history under /data/adb/kurumi_monitor. No partition writes,
// no kernel-source changes, no wakelock held by the monitor.
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
//     - thermal settings + cpufreq floor re-check every 10h (idempotent;
//       silently re-applies if something restored them).
// =====================================================================

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

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
const THERMAL_RECHECK_SECS: u64 = 10 * 3600;
const MONITOR_INTERVAL_SECS: u64 = 3600;

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
// on the 3h/10h re-checks).
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

fn apply_ufs_policy() {
    // The two UFS paths are aliases on this device. Write the first existing
    // one only to avoid duplicate work.
    for base in UFS_BASES {
        let base = Path::new(base);
        if !base.exists() {
            continue;
        }
        write_if_diff(base.join("clkgate_enable"), IO_UFS_CLKGATE);
        write_if_diff(base.join("clkscale_enable"), IO_UFS_CLKSCALE);
        break;
    }
}

fn is_target_block_device(name: &str) -> bool {
    name.starts_with("dm-")
        || name.starts_with("sd")
        || name.starts_with("mmcblk")
        || name.starts_with("nvme")
}

fn apply_read_ahead() {
    if let Ok(entries) = fs::read_dir("/sys/block") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !is_target_block_device(&name) {
                continue;
            }
            write_if_diff(
                entry.path().join("queue").join("read_ahead_kb"),
                IO_READ_AHEAD_KB,
            );
        }
    }
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

fn apply_cpufreq_limits() {
    for &(policy, min, max) in CPUFREQ_LIMITS {
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

// ---------- event-driven: touch-boost ----------

fn maybe_pulse(last: &Arc<Mutex<Instant>>) {
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
fn touch_loop(path: std::path::PathBuf, last: Arc<Mutex<Instant>>) {
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
                    maybe_pulse(&last);
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

fn spawn_touch_threads(last: Arc<Mutex<Instant>>) {
    if let Ok(entries) = fs::read_dir("/dev/input") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.starts_with("event") {
                continue;
            }
            let path = entry.path();
            let last = Arc::clone(&last);
            thread::spawn(move || touch_loop(path, last));
        }
    }
}


// ---------- hourly power monitor / boot-session recorder ----------
// This is intentionally userspace-only. The kernel remains a source of counters;
// it never writes /data. The daemon samples once per hour, plus a baseline after
// boot_completed, and stores history by boot_id so counters from different boots
// are never mixed.

const MONITOR_ROOT: &str = "/data/adb/kurumi_monitor";
const MONITOR_VERSION: &str = "1";

#[cfg(feature = "eco")]
const KURUMI_PROFILE: &str = "eco";
#[cfg(feature = "balance")]
const KURUMI_PROFILE: &str = "balance";
#[cfg(feature = "full")]
const KURUMI_PROFILE: &str = "full";

#[derive(Clone)]
struct PowerMonitor {
    enabled: bool,
    root: PathBuf,
    boot_id: String,
    boot_dir: PathBuf,
    snapshot_seq: u64,
}

fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn read_trim<P: AsRef<Path>>(path: P) -> String {
    fs::read_to_string(path)
        .map(|s| s.trim_matches(|c| c == '\n' || c == '\r' || c == '\0').to_string())
        .unwrap_or_default()
}

fn read_first_existing(paths: &[&str]) -> String {
    for p in paths {
        let s = read_trim(p);
        if !s.is_empty() {
            return s;
        }
    }
    String::new()
}

fn tsv_escape(s: &str) -> String {
    s.replace('\t', " ")
        .replace('\r', " ")
        .replace('\n', " ")
        .replace('\0', " ")
}

fn append_tsv(path: &Path, header: &str, row: &str) -> bool {
    if let Some(parent) = path.parent() {
        if fs::create_dir_all(parent).is_err() {
            return false;
        }
    }
    let need_header = !path.exists() || fs::metadata(path).map(|m| m.len() == 0).unwrap_or(true);
    let mut f = match OpenOptions::new().create(true).append(true).open(path) {
        Ok(f) => f,
        Err(_) => return false,
    };
    if need_header {
        let _ = writeln!(f, "{}", header);
    }
    writeln!(f, "{}", row).is_ok()
}

fn command_output(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

fn uptime_secs() -> u64 {
    read_trim("/proc/uptime")
        .split_whitespace()
        .next()
        .and_then(|s| s.split('.').next())
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0)
}

fn boot_id() -> String {
    let id = read_trim("/proc/sys/kernel/random/boot_id");
    if !id.is_empty() {
        return id;
    }
    format!("unknown-{}", now_epoch_secs())
}

fn android_prop(key: &str) -> String {
    command_output("getprop", &[key])
}

fn screen_state() -> String {
    let mut saw_backlight = false;
    let roots = ["/sys/class/backlight", "/sys/class/leds/lcd-backlight"];
    for root in roots {
        if let Ok(entries) = fs::read_dir(root) {
            for e in entries.flatten() {
                let p = e.path();
                let b = read_trim(p.join("actual_brightness"));
                let b = if b.is_empty() { read_trim(p.join("brightness")) } else { b };
                if b.is_empty() {
                    continue;
                }
                saw_backlight = true;
                if b.parse::<i64>().unwrap_or(0) > 0 {
                    return "on".to_string();
                }
            }
        }
    }
    if saw_backlight {
        "off".to_string()
    } else {
        "unknown".to_string()
    }
}

fn power_supply_value(name: &str, field: &str) -> String {
    read_trim(format!("/sys/class/power_supply/{}/{}", name, field))
}

fn any_power_online() -> String {
    let mut online: Vec<String> = Vec::new();
    if let Ok(entries) = fs::read_dir("/sys/class/power_supply") {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name == "battery" {
                continue;
            }
            let val = read_trim(e.path().join("online"));
            if val == "1" {
                online.push(name);
            }
        }
    }
    if online.is_empty() {
        "none".to_string()
    } else {
        online.join(",")
    }
}

fn package_map() -> Vec<(String, String)> {
    let out = command_output("cmd", &["package", "list", "packages", "-U"]);
    let mut rows = Vec::new();
    for line in out.lines() {
        let line = line.trim();
        if !line.starts_with("package:") {
            continue;
        }
        let without = &line[8..];
        let mut parts = without.split_whitespace();
        let pkg = parts.next().unwrap_or("").to_string();
        let mut uid = String::new();
        for p in parts {
            if let Some(v) = p.strip_prefix("uid:") {
                uid = v.to_string();
                break;
            }
        }
        if !pkg.is_empty() && !uid.is_empty() {
            rows.push((uid, pkg));
        }
    }
    rows
}

fn parse_status_uid_rss(status: &str) -> (String, String, String) {
    let mut uid = String::new();
    let mut rss_kb = String::new();
    let mut name = String::new();
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("Name:") {
            name = rest.trim().to_string();
        } else if let Some(rest) = line.strip_prefix("Uid:") {
            uid = rest.split_whitespace().next().unwrap_or("").to_string();
        } else if let Some(rest) = line.strip_prefix("VmRSS:") {
            rss_kb = rest.split_whitespace().next().unwrap_or("").to_string();
        }
    }
    (uid, rss_kb, name)
}

fn parse_proc_stat_cpu(stat: &str) -> (String, String) {
    if let Some(end) = stat.rfind(')') {
        let after = stat.get(end + 2..).unwrap_or("");
        let fields: Vec<&str> = after.split_whitespace().collect();
        // fields[0] is state; utime/stime are Linux stat fields 14/15.
        let utime = fields.get(11).copied().unwrap_or("");
        let stime = fields.get(12).copied().unwrap_or("");
        return (utime.to_string(), stime.to_string());
    }
    (String::new(), String::new())
}

fn parse_proc_io(io: &str) -> (String, String) {
    let mut read_bytes = String::new();
    let mut write_bytes = String::new();
    for line in io.lines() {
        if let Some(rest) = line.strip_prefix("read_bytes:") {
            read_bytes = rest.trim().to_string();
        } else if let Some(rest) = line.strip_prefix("write_bytes:") {
            write_bytes = rest.trim().to_string();
        }
    }
    (read_bytes, write_bytes)
}

impl PowerMonitor {
    fn new() -> PowerMonitor {
        let root = PathBuf::from(MONITOR_ROOT);
        let id = boot_id();
        let boot_dir = root.join("boots").join(&id);
        let enabled = fs::create_dir_all(&boot_dir).is_ok();
        let mut mon = PowerMonitor {
            enabled,
            root,
            boot_id: id,
            boot_dir,
            snapshot_seq: 0,
        };
        if mon.enabled {
            mon.init_boot_session();
            mon.refresh_package_map();
            mon.install_report_helper();
        }
        mon
    }

    fn init_boot_session(&mut self) {
        let boot_file = self.root.join("boot_sessions.tsv");
        let existing = fs::read_to_string(&boot_file).unwrap_or_default();
        if existing.contains(&self.boot_id) {
            self.snapshot_seq = self.count_existing_snapshots();
            return;
        }
        let now = now_epoch_secs();
        let up = uptime_secs();
        let boot_start = now.saturating_sub(up);
        let kernel = read_trim("/proc/sys/kernel/osrelease");
        let android_build = android_prop("ro.build.fingerprint");
        let rom = android_prop("ro.build.version.incremental");
        let row = format!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            tsv_escape(&self.boot_id),
            now,
            boot_start,
            up,
            tsv_escape(&kernel),
            tsv_escape(&android_build),
            tsv_escape(&rom),
            KURUMI_PROFILE
        );
        append_tsv(
            &boot_file,
            "boot_id\tfirst_seen_epoch\tboot_start_epoch\tuptime_sec\tkernel_release\tandroid_build\trom_build\tkurumi_profile",
            &row,
        );
        let meta = self.boot_dir.join("meta.tsv");
        append_tsv(
            &meta,
            "key\tvalue",
            &format!("monitor_version\t{}", MONITOR_VERSION),
        );
        append_tsv(&meta, "key\tvalue", &format!("boot_id\t{}", tsv_escape(&self.boot_id)));
        append_tsv(&meta, "key\tvalue", &format!("kernel_release\t{}", tsv_escape(&kernel)));
        append_tsv(&meta, "key\tvalue", &format!("android_build\t{}", tsv_escape(&android_build)));
        append_tsv(&meta, "key\tvalue", &format!("kurumi_profile\t{}", KURUMI_PROFILE));
    }

    fn count_existing_snapshots(&self) -> u64 {
        fs::read_to_string(self.boot_dir.join("snapshots.tsv"))
            .map(|s| s.lines().skip(1).count() as u64)
            .unwrap_or(0)
    }

    fn install_report_helper(&self) {
        // Helpful for Magisk overlay mode where the daemon binary lives in MAGISKTMP.
        // Users can later run: /data/adb/kurumi_monitor/kurumi --monitor-report
        if let Ok(exe) = std::env::current_exe() {
            let dst = self.root.join("kurumi");
            let same_file = fs::canonicalize(&exe)
                .ok()
                .zip(fs::canonicalize(&dst).ok())
                .map(|(a, b)| a == b)
                .unwrap_or(false);
            if same_file {
                return;
            }
            if fs::copy(exe, &dst).is_ok() {
                if let Ok(md) = fs::metadata(&dst) {
                    let mut perm = md.permissions();
                    perm.set_mode(0o755);
                    let _ = fs::set_permissions(&dst, perm);
                }
            }
        }
    }

    fn refresh_package_map(&self) {
        let path = self.boot_dir.join("packages.tsv");
        if path.exists() {
            return;
        }
        for (uid, pkg) in package_map() {
            let row = format!("{}\t{}", tsv_escape(&uid), tsv_escape(&pkg));
            append_tsv(&path, "uid\tpackage", &row);
        }
    }

    fn snapshot(&mut self, reason: &str) {
        if !self.enabled {
            return;
        }
        self.snapshot_seq += 1;
        let now = now_epoch_secs();
        let up = uptime_secs();
        let snap = self.snapshot_seq;
        self.write_snapshot_row(snap, now, up, reason);
        self.collect_wakeup_sources(snap, now);
        self.collect_interrupts(snap, now);
        self.collect_network(snap, now);
        self.collect_thermal(snap, now);
        self.collect_uid_counters(snap, now);
        self.collect_processes(snap, now);
        self.collect_kernel_events(snap, now);
        let _ = fs::write(self.root.join("last_snapshot_epoch"), format!("{}\n", now));
    }

    fn write_snapshot_row(&self, snap: u64, now: u64, up: u64, reason: &str) {
        let capacity = power_supply_value("battery", "capacity");
        let status = power_supply_value("battery", "status");
        let current_now = power_supply_value("battery", "current_now");
        let voltage_now = power_supply_value("battery", "voltage_now");
        let temp = power_supply_value("battery", "temp");
        let charge_counter = power_supply_value("battery", "charge_counter");
        let health = power_supply_value("battery", "health");
        let power_online = any_power_online();
        let screen = screen_state();
        let row = format!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            snap,
            now,
            up,
            tsv_escape(reason),
            tsv_escape(&screen),
            tsv_escape(&power_online),
            tsv_escape(&capacity),
            tsv_escape(&status),
            tsv_escape(&current_now),
            tsv_escape(&voltage_now),
            tsv_escape(&temp),
            tsv_escape(&charge_counter),
            tsv_escape(&health),
        );
        append_tsv(
            &self.boot_dir.join("snapshots.tsv"),
            "snapshot_id\tepoch\tuptime_sec\treason\tscreen\tpower_online\tbattery_capacity\tbattery_status\tcurrent_now\tvoltage_now\tbattery_temp\tcharge_counter\thealth",
            &row,
        );
    }

    fn collect_wakeup_sources(&self, snap: u64, now: u64) {
        let src = read_first_existing(&[
            "/sys/kernel/debug/wakeup_sources",
            "/d/wakeup_sources",
        ]);
        if src.is_empty() {
            return;
        }
        let path = self.boot_dir.join("wakeup_sources.tsv");
        for line in src.lines().skip(1) {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.is_empty() {
                continue;
            }
            let name = cols[0];
            let active_count = cols.get(1).copied().unwrap_or("");
            let event_count = cols.get(2).copied().unwrap_or("");
            let wakeup_count = cols.get(3).copied().unwrap_or("");
            let expire_count = cols.get(4).copied().unwrap_or("");
            let active_since = cols.get(5).copied().unwrap_or("");
            let total_time = cols.get(6).copied().unwrap_or("");
            let max_time = cols.get(7).copied().unwrap_or("");
            let last_change = cols.get(8).copied().unwrap_or("");
            let prevent_suspend = cols.get(9).copied().unwrap_or("");
            let row = format!(
                "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                snap,
                now,
                tsv_escape(name),
                active_count,
                event_count,
                wakeup_count,
                expire_count,
                active_since,
                total_time,
                max_time,
                last_change,
                prevent_suspend,
            );
            append_tsv(
                &path,
                "snapshot_id\tepoch\tname\tactive_count\tevent_count\twakeup_count\texpire_count\tactive_since_ms\ttotal_time_ms\tmax_time_ms\tlast_change_ms\tprevent_suspend_time_ms",
                &row,
            );
        }
    }

    fn collect_interrupts(&self, snap: u64, now: u64) {
        let data = read_trim("/proc/interrupts");
        if data.is_empty() {
            return;
        }
        let path = self.boot_dir.join("interrupts.tsv");
        for line in data.lines() {
            let line = line.trim();
            if !line.contains(':') || line.starts_with("CPU") {
                continue;
            }
            let mut parts = line.splitn(2, ':');
            let irq = parts.next().unwrap_or("").trim();
            let rest = parts.next().unwrap_or("").trim();
            let cols: Vec<&str> = rest.split_whitespace().collect();
            if cols.is_empty() {
                continue;
            }
            let mut sum: u64 = 0;
            let mut idx = 0usize;
            while idx < cols.len() {
                if let Ok(v) = cols[idx].parse::<u64>() {
                    sum = sum.saturating_add(v);
                    idx += 1;
                } else {
                    break;
                }
            }
            let name = cols.get(idx..).map(|s| s.join(" ")).unwrap_or_default();
            let row = format!("{}\t{}\t{}\t{}\t{}", snap, now, tsv_escape(irq), sum, tsv_escape(&name));
            append_tsv(&path, "snapshot_id\tepoch\tirq\ttotal_count\tname", &row);
        }
    }

    fn collect_network(&self, snap: u64, now: u64) {
        let base = Path::new("/sys/class/net");
        let entries = match fs::read_dir(base) {
            Ok(e) => e,
            Err(_) => return,
        };
        let path = self.boot_dir.join("network.tsv");
        for e in entries.flatten() {
            let ifname = e.file_name().to_string_lossy().to_string();
            let st = e.path().join("statistics");
            if !st.is_dir() {
                continue;
            }
            let rx_bytes = read_trim(st.join("rx_bytes"));
            let tx_bytes = read_trim(st.join("tx_bytes"));
            let rx_packets = read_trim(st.join("rx_packets"));
            let tx_packets = read_trim(st.join("tx_packets"));
            let row = format!(
                "{}\t{}\t{}\t{}\t{}\t{}\t{}",
                snap,
                now,
                tsv_escape(&ifname),
                rx_bytes,
                tx_bytes,
                rx_packets,
                tx_packets
            );
            append_tsv(&path, "snapshot_id\tepoch\tinterface\trx_bytes\ttx_bytes\trx_packets\ttx_packets", &row);
        }
    }

    fn collect_thermal(&self, snap: u64, now: u64) {
        let entries = match fs::read_dir("/sys/class/thermal") {
            Ok(e) => e,
            Err(_) => return,
        };
        let path = self.boot_dir.join("thermal.tsv");
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if !name.starts_with("thermal_zone") {
                continue;
            }
            let ty = read_trim(e.path().join("type"));
            let temp = read_trim(e.path().join("temp"));
            if ty.is_empty() && temp.is_empty() {
                continue;
            }
            let row = format!("{}\t{}\t{}\t{}\t{}", snap, now, tsv_escape(&name), tsv_escape(&ty), tsv_escape(&temp));
            append_tsv(&path, "snapshot_id\tepoch\tzone\ttype\ttemp", &row);
        }
    }

    fn collect_uid_counters(&self, snap: u64, now: u64) {
        let path = self.boot_dir.join("uid_usage.tsv");
        let tis = read_trim("/proc/uid_time_in_state");
        if !tis.is_empty() {
            for line in tis.lines() {
                let line = line.trim();
                if line.is_empty() || !line.contains(':') || line.starts_with("uid") {
                    continue;
                }
                let mut parts = line.splitn(2, ':');
                let uid = parts.next().unwrap_or("").trim();
                let vals = parts.next().unwrap_or("");
                let total: u64 = vals
                    .split_whitespace()
                    .filter_map(|v| v.parse::<u64>().ok())
                    .fold(0u64, |a, b| a.saturating_add(b));
                let row = format!("{}\t{}\t{}\t{}\t{}", snap, now, tsv_escape(uid), total, tsv_escape(vals));
                append_tsv(&path, "snapshot_id\tepoch\tuid\ttime_in_state_total\ttime_in_state_raw", &row);
            }
        }
        let uid_io = read_trim("/proc/uid_io/stats");
        if !uid_io.is_empty() {
            let io_path = self.boot_dir.join("uid_io.tsv");
            for line in uid_io.lines() {
                let cols: Vec<&str> = line.split_whitespace().collect();
                if cols.is_empty() || cols[0].parse::<u32>().is_err() {
                    continue;
                }
                let row = format!("{}\t{}\t{}", snap, now, tsv_escape(line));
                append_tsv(&io_path, "snapshot_id\tepoch\tuid_io_raw", &row);
            }
        }
    }

    fn collect_processes(&self, snap: u64, now: u64) {
        let entries = match fs::read_dir("/proc") {
            Ok(e) => e,
            Err(_) => return,
        };
        let path = self.boot_dir.join("processes.tsv");
        for e in entries.flatten() {
            let pid_s = e.file_name().to_string_lossy().to_string();
            if pid_s.parse::<u32>().is_err() {
                continue;
            }
            let base = e.path();
            let status = fs::read_to_string(base.join("status")).unwrap_or_default();
            if status.is_empty() {
                continue;
            }
            let (uid, rss_kb, status_name) = parse_status_uid_rss(&status);
            let cmdline = fs::read(base.join("cmdline"))
                .ok()
                .map(|b| String::from_utf8_lossy(&b).replace('\0', " ").trim().to_string())
                .unwrap_or_default();
            let comm = if cmdline.is_empty() { status_name } else { cmdline };
            let stat = fs::read_to_string(base.join("stat")).unwrap_or_default();
            let (utime, stime) = parse_proc_stat_cpu(&stat);
            let io = fs::read_to_string(base.join("io")).unwrap_or_default();
            let (read_bytes, write_bytes) = parse_proc_io(&io);
            let row = format!(
                "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                snap,
                now,
                tsv_escape(&pid_s),
                tsv_escape(&uid),
                tsv_escape(&comm),
                tsv_escape(&utime),
                tsv_escape(&stime),
                tsv_escape(&rss_kb),
                tsv_escape(&read_bytes),
                tsv_escape(&write_bytes)
            );
            append_tsv(
                &path,
                "snapshot_id\tepoch\tpid\tuid\tcmd\tutime_ticks\tstime_ticks\trss_kb\tread_bytes\twrite_bytes",
                &row,
            );
        }
    }

    fn collect_kernel_events(&self, snap: u64, now: u64) {
        let out = command_output("dmesg", &[]);
        if out.is_empty() {
            return;
        }
        let path = self.boot_dir.join("kernel_events.tsv");
        let keys = [
            "suspend", "resume", "wakeup", "wlan", "wifi", "cnss", "mhi", "pcie", "thermal",
            "battery", "charger", "ufs", "wakelock", "irq",
        ];
        for line in out.lines().rev().take(400) {
            let low = line.to_ascii_lowercase();
            if keys.iter().any(|k| low.contains(k)) {
                let row = format!("{}\t{}\t{}", snap, now, tsv_escape(line));
                append_tsv(&path, "snapshot_id\tepoch\tevent", &row);
            }
        }
    }
}

#[derive(Default)]
struct BootReport {
    boot_id: String,
    first_epoch: u64,
    last_epoch: u64,
    snapshots: u64,
    battery_start: String,
    battery_end: String,
    charge_start: String,
    charge_end: String,
    max_temp: i64,
}

fn split_tsv_line(line: &str) -> Vec<&str> {
    line.split('\t').collect()
}

fn build_monitor_report() -> Option<PathBuf> {
    let root = PathBuf::from(MONITOR_ROOT);
    let boots_root = root.join("boots");
    let mut reports: Vec<BootReport> = Vec::new();
    let entries = fs::read_dir(&boots_root).ok()?;
    for e in entries.flatten() {
        let boot_id = e.file_name().to_string_lossy().to_string();
        let snapshots = fs::read_to_string(e.path().join("snapshots.tsv")).unwrap_or_default();
        let mut br = BootReport { boot_id, max_temp: i64::MIN, ..BootReport::default() };
        for line in snapshots.lines().skip(1) {
            let cols = split_tsv_line(line);
            if cols.len() < 13 {
                continue;
            }
            let epoch = cols[1].parse::<u64>().unwrap_or(0);
            if br.snapshots == 0 {
                br.first_epoch = epoch;
                br.battery_start = cols[6].to_string();
                br.charge_start = cols[11].to_string();
            }
            br.snapshots += 1;
            br.last_epoch = epoch;
            br.battery_end = cols[6].to_string();
            br.charge_end = cols[11].to_string();
            if let Ok(t) = cols[10].parse::<i64>() {
                br.max_temp = br.max_temp.max(t);
            }
        }
        if br.snapshots > 0 {
            reports.push(br);
        }
    }
    reports.sort_by_key(|r| r.first_epoch);
    fs::create_dir_all(root.join("reports")).ok()?;
    let out_path = root.join("reports").join(format!("report_{}.tsv", now_epoch_secs()));
    let mut out = File::create(&out_path).ok()?;
    let _ = writeln!(out, "# Kurumi Power Monitor report");
    let _ = writeln!(out, "# No verdicts, raw boot-session summary only");
    let _ = writeln!(out, "boot_id\tfirst_epoch\tlast_epoch\tduration_sec\tsnapshots\tbattery_start\tbattery_end\tcharge_counter_start\tcharge_counter_end\tmax_battery_temp_raw");
    for r in reports {
        let duration = r.last_epoch.saturating_sub(r.first_epoch);
        let max_temp = if r.max_temp == i64::MIN { String::new() } else { r.max_temp.to_string() };
        let _ = writeln!(
            out,
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            tsv_escape(&r.boot_id),
            r.first_epoch,
            r.last_epoch,
            duration,
            r.snapshots,
            tsv_escape(&r.battery_start),
            tsv_escape(&r.battery_end),
            tsv_escape(&r.charge_start),
            tsv_escape(&r.charge_end),
            max_temp,
        );
    }
    Some(out_path)
}

fn monitor_cli(args: &[String]) -> bool {
    if args.len() < 2 {
        return false;
    }
    match args[1].as_str() {
        "--monitor-snapshot" => {
            let mut mon = PowerMonitor::new();
            mon.snapshot("manual");
            true
        }
        "--monitor-report" => {
            if let Some(path) = build_monitor_report() {
                println!("{}", path.display());
            }
            true
        }
        _ => false,
    }
}

// ---------- main ----------

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if monitor_cli(&args) {
        return;
    }

    // Start persistent, low-rate power history. The first sample is only a
    // boot-session baseline; hourly deltas are interpreted inside the same boot_id.
    let mut monitor = PowerMonitor::new();
    monitor.snapshot("boot_baseline");

    // Touch-boost threads start immediately; they block on input (~0 CPU idle).
    let last_touch = Arc::new(Mutex::new(Instant::now() - Duration::from_secs(3600)));
    spawn_touch_threads(Arc::clone(&last_touch));

    // One-time setup, after vendor thermal services have come up so `stop` bites.
    thread::sleep(Duration::from_secs(BOOT_WAIT_SECS));
    disable_thermal_services();
    apply_core_ctl();
    apply_cpufreq_limits();
    apply_memory();
    apply_surfaceflinger();
    apply_io_profile();
    apply_wifi_sleep_profile();

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

    // Steady state: hourly tick. WALT/VM every 3h, thermal re-check every 10h,
    // and Kurumi Power Monitor snapshot exactly once per hour.
    let mut walt_acc: u64 = 0;
    let mut therm_acc: u64 = 0;
    let mut monitor_acc: u64 = 0;
    loop {
        thread::sleep(Duration::from_secs(STEADY_TICK_SECS));
        walt_acc += STEADY_TICK_SECS;
        therm_acc += STEADY_TICK_SECS;
        monitor_acc += STEADY_TICK_SECS;
        if monitor_acc >= MONITOR_INTERVAL_SECS {
            monitor.snapshot("hourly");
            monitor_acc = 0;
        }
        if walt_acc >= WALT_STEADY_SECS {
            apply_walt_vm();
            walt_acc = 0;
        }
        if therm_acc >= THERMAL_RECHECK_SECS {
            disable_thermal_services();
            apply_cpufreq_limits();
            therm_acc = 0;
        }
    }
}
