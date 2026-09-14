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
//   Once at start (after a short wait so vendor post-boot policy has settled):
//     - core_ctl on the big clusters (cpu2/cpu5/cpu7): allow core sleep.
//     - cpufreq profile CEILINGS only. The kernel-native Kurumi base-min guard
//       owns scaling_min_freq and keeps the sysfs base request at the real HW
//       minimum while preserving independent WALT/input freq_qos boosts.
//     - thermal services/zones/cooling devices are NOT touched here. The
//       kernel-native Kurumi performance guard accepts CPU/GPU/display thermal
//       requests but clamps their effective cooling state to 0, while leaving
//       critical/battery/BCL/PMIC/UFS/DDR/modem and LMH protections intact.
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

// ---- core_ctl: first CPU of each BIG cluster. Topology is 2+3+2+1:
//      cpu0-1 (little, left alone) | cpu2-4 | cpu5-6 | cpu7. core_ctl nodes live
//      only on a cluster's first cpu -> cpu2, cpu5, cpu7. ----
const CORE_CTL_CPUS: &[u32] = &[2, 5, 7];

// ---- touch-boost ----
const SCHED_USER_HINT: &str = "/proc/sys/walt/sched_user_hint";
const TOUCH_HINT_VALUE: &str = "500";
const TOUCH_DEBOUNCE_MS: u64 = 400;

// ---- timing ----
const POST_BOOT_SETTLE_SECS: u64 = 90;
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
const SCREEN_OFF_CPUFREQ_MAX_LIMITS: &[(u32, &str)] = &[
    (0, "1812480"),
    (2, "2204160"),
    (5, "1182720"),
    (7, "1320960"),
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
// main() then sleeps POST_BOOT_SETTLE_SECS (90s). This means these I/O tunables are
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

// ---------- one-time + screen-state: cpufreq profile ceilings ----------
//
// The kernel-native KURUMI_CPU_BASE_MIN_GUARD owns the sysfs base-min request,
// so userspace no longer writes scaling_min_freq. This deliberately preserves
// independent freq_qos clients such as WALT input boost (e.g. the short
// policy0 1248000 kHz pulse observed on-device).
//
// Profile is chosen at BUILD time via a cargo feature (eco|balance|full). CI
// compiles one binary per profile from this source and the flasher installs the
// selected one. Values below are maximum ceilings only (KHz):
//   policy0 = cpu0-1 little, policy2 = cpu2-4, policy5 = cpu5-6, policy7 = prime.
#[cfg(feature = "full")]
const CPUFREQ_MAX_LIMITS: &[(u32, &str)] = &[
    (0, "2265600"),
    (2, "3148800"),
    (5, "2956800"),
    (7, "3302400"),
];

#[cfg(feature = "eco")]
const CPUFREQ_MAX_LIMITS: &[(u32, &str)] = &[
    (0, "1812480"),
    (2, "2204160"),
    (5, "1182720"),
    (7, "1320960"),
];

#[cfg(feature = "balance")]
const CPUFREQ_MAX_LIMITS: &[(u32, &str)] = &[
    (0, "2265600"),
    (2, "2519040"),
    (5, "2069760"),
    (7, "2311680"),
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

fn apply_cpufreq_max_table(limits: &[(u32, &str)]) {
    for &(policy, max) in limits {
        let base = format!("/sys/devices/system/cpu/cpufreq/policy{}", policy);
        if !Path::new(&base).exists() {
            continue;
        }
        write_if_diff(format!("{}/scaling_max_freq", base), max);
    }
}

fn apply_cpufreq_limits() {
    apply_cpufreq_max_table(CPUFREQ_MAX_LIMITS);
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
    apply_cpufreq_max_table(SCREEN_OFF_CPUFREQ_MAX_LIMITS);
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

// ---------- one-time: modem remoteproc SSR recovery ----------
// The Nubia kernel hardcodes recovery_disabled=true for every PAS remoteproc
// (drivers/remoteproc/qcom_q6v5_pas.c:1832), so a modem firmware fatal error
// panics the whole device into Qualcomm CrashDump instead of restarting the
// modem ("rproc recovery state: disabled and lead to device crash"). Observed
// in the wild: lte_rrc_plmn_search.c:9211 assert during PLMN search.
//
// The remoteproc core is built into the GKI Image (CONFIG_REMOTEPROC=y) and
// exposes a runtime switch at /sys/class/remoteproc/remoteproc*/recovery; the
// PAS driver keeps its internal cache in sync via the
// android_vh_rproc_recovery_set vendor hook, so the toggle is respected.
// Enable it for the modem so a crash becomes a short modem SSR instead.

fn apply_modem_recovery() {
    if let Ok(entries) = fs::read_dir("/sys/class/remoteproc") {
        for entry in entries.flatten() {
            let name = match read_trim(entry.path().join("name")) {
                Some(n) => n,
                None => continue,
            };
            if !name.ends_with("remoteproc-mss") {
                continue;
            }
            let recovery = entry.path().join("recovery");
            if read_trim(&recovery).as_deref() != Some("enabled") {
                write_val(&recovery, "enabled");
            }
            break;
        }
    }
}

// ---------- main ----------

fn main() {
    // Enable modem SSR recovery before anything else: the modem is up by
    // boot_completed and every second without recovery is a crash window.
    apply_modem_recovery();

    // Touch-boost threads start immediately; they block on input (~0 CPU idle).
    let last_touch = Arc::new(Mutex::new(Instant::now() - Duration::from_secs(3600)));
    let screen_active = Arc::new(AtomicBool::new(true));
    spawn_touch_threads(Arc::clone(&last_touch), Arc::clone(&screen_active));

    // One-time userspace setup after vendor post-boot tunables have settled.
    // Thermal protection policy is active in-kernel from the beginning of boot.
    thread::sleep(Duration::from_secs(POST_BOOT_SETTLE_SECS));
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
