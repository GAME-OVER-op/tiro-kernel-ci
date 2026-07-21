// =====================================================================
// Kurumi kernel userspace daemon (RedMagic 9 Pro, SM8650 / pineapple)
//
// Replaces the old shell `kurumi_battery`. Pure std (no external crates) so it
// builds to a fully-static aarch64 musl binary that runs on Android bionic.
//
// It writes ONLY to /sys and /proc -> fully reversible, no partition writes,
// NO kernel-source changes. No logging (settings are just applied).
//
// Behaviour:
//   Once at start (after a short wait so vendor thermal services are up):
//     - disable_thermal_services(): faithful port of mora's 6-stage burn-mode
//       (stop services -> setprop -> pkill survivors -> zone mode=disabled ->
//        cooling cur_state=0 -> unbind userspace LMh). Battery zone 74 untouched.
//     - core_ctl on the big clusters (cpu2/cpu5/cpu7): allow core sleep.
//     - vm.max_map_count = 1048576 (headroom for Wine/Winlator emulators).
//   Event-driven:
//     - touch-boost: block-read /dev/input/event* in threads (~0 CPU idle);
//       on input, pulse /proc/sys/walt/sched_user_hint (auto-decays), debounced.
//   Periodic:
//     - WALT + VM tunables: burst every 60s for the first 20 min (WALT governor
//       comes up late), then re-assert every 3h (idempotent).
//     - thermal settings re-check every 10h (idempotent; silently re-applies if
//       something restored them).
// =====================================================================

use std::fs::{self, File};
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;
use std::sync::{Arc, Mutex};
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
const THERMAL_RECHECK_SECS: u64 = 10 * 3600;

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

// ---------- main ----------

fn main() {
    // Touch-boost threads start immediately; they block on input (~0 CPU idle).
    let last_touch = Arc::new(Mutex::new(Instant::now() - Duration::from_secs(3600)));
    spawn_touch_threads(Arc::clone(&last_touch));

    // One-time setup, after vendor thermal services have come up so `stop` bites.
    thread::sleep(Duration::from_secs(BOOT_WAIT_SECS));
    disable_thermal_services();
    apply_core_ctl();
    apply_memory();

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

    // Steady state: hourly tick. WALT/VM every 3h, thermal re-check every 10h.
    let mut walt_acc: u64 = 0;
    let mut therm_acc: u64 = 0;
    loop {
        thread::sleep(Duration::from_secs(STEADY_TICK_SECS));
        walt_acc += STEADY_TICK_SECS;
        therm_acc += STEADY_TICK_SECS;
        if walt_acc >= WALT_STEADY_SECS {
            apply_walt_vm();
            walt_acc = 0;
        }
        if therm_acc >= THERMAL_RECHECK_SECS {
            disable_thermal_services();
            therm_acc = 0;
        }
    }
}
