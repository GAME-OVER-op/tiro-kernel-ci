// SPDX-License-Identifier: GPL-2.0
//
// Kurumi Fan Governor.
//
// The Nubia fan driver remains the only hardware driver.  This module is a
// userspace policy layer that synchronizes the Nubia Settings.Global values
// with /sys/kernel/fan, applies temperature curves, and yields permanently to
// a manual speed change until automatic mode is toggled off and on again.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

const FAN_ENABLE_PATH: &str = "/sys/kernel/fan/fan_enable";
const FAN_LEVEL_PATH: &str = "/sys/kernel/fan/fan_speed_level";

const GLOBAL_FAN_ENABLE: &str = "nubia_parts_fan_enable";
const GLOBAL_FAN_LEVEL: &str = "nubia_parts_fan_speed_level";

const INITIALIZATION_SECS: u64 = 30;
const POLL_SECS: u64 = 5;
const PROBE_REFRESH_SECS: u64 = 60;
const LOWER_CONFIRMATIONS: u8 = 3;

const CPU_ZONE_IDS: &[u32] = &[
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 25, 26, 27, 28, 29,
];
const GPU_ZONE_IDS: &[u32] = &[41, 42, 43, 44, 45, 46, 47, 48];
const BATTERY_ZONE_ID: u32 = 74;

#[derive(Clone, Copy)]
struct Snapshot {
    global_auto: bool,
    global_level: u8,
    sysfs_enable: bool,
    sysfs_level: u8,
}

#[derive(Clone, Copy)]
struct RuntimeContext {
    screen_on: bool,
    charging_effective: bool,
}

impl RuntimeContext {
    fn should_suspend(self) -> bool {
        !self.screen_on && !self.charging_effective
    }
}

struct ThermalPaths {
    cpu: Vec<PathBuf>,
    gpu: Vec<PathBuf>,
    battery: Option<PathBuf>,
}

impl ThermalPaths {
    fn configured() -> Self {
        Self {
            cpu: CPU_ZONE_IDS.iter().map(|id| thermal_path(*id)).collect(),
            gpu: GPU_ZONE_IDS.iter().map(|id| thermal_path(*id)).collect(),
            battery: Some(thermal_path(BATTERY_ZONE_ID)),
        }
    }

    fn soc_temp_mc(&self) -> Option<i32> {
        match (average_temp_mc(&self.cpu), average_temp_mc(&self.gpu)) {
            (Some(cpu), Some(gpu)) => Some(cpu.max(gpu)),
            (Some(cpu), None) => Some(cpu),
            (None, Some(gpu)) => Some(gpu),
            (None, None) => None,
        }
    }

    fn battery_temp_mc(&self) -> Option<i32> {
        read_i32(self.battery.as_ref()?)
    }
}

struct ChargeProbe {
    online_paths: Vec<PathBuf>,
    battery_status_path: Option<PathBuf>,
    battery_capacity_path: Option<PathBuf>,
}

impl ChargeProbe {
    fn detect() -> Self {
        let mut online_paths = Vec::new();
        let mut battery_status_path = None;
        let mut battery_capacity_path = None;

        if let Ok(entries) = fs::read_dir("/sys/class/power_supply") {
            for entry in entries.flatten() {
                let path = entry.path();
                if !path.is_dir() {
                    continue;
                }

                let supply_type = read_trim(path.join("type")).unwrap_or_default();
                if supply_type.eq_ignore_ascii_case("Battery") {
                    let status = path.join("status");
                    if status.exists() && battery_status_path.is_none() {
                        battery_status_path = Some(status);
                    }
                    let capacity = path.join("capacity");
                    if capacity.exists() && battery_capacity_path.is_none() {
                        battery_capacity_path = Some(capacity);
                    }
                    continue;
                }

                let online = path.join("online");
                if online.exists() {
                    online_paths.push(online);
                }
            }
        }

        Self {
            online_paths,
            battery_status_path,
            battery_capacity_path,
        }
    }

    fn is_charging(&self) -> bool {
        if self
            .online_paths
            .iter()
            .any(|path| read_u8(path) == Some(1))
        {
            return true;
        }

        self.battery_status_path
            .as_ref()
            .and_then(read_trim)
            .map(|status| {
                status.eq_ignore_ascii_case("Charging")
                    || status.eq_ignore_ascii_case("Full")
            })
            .unwrap_or(false)
    }

    fn battery_percent(&self) -> Option<u8> {
        read_u8(self.battery_capacity_path.as_ref()?).map(|value| value.min(100))
    }
}

struct KurumiFanGovernor {
    initialization_started: Option<Instant>,
    initialized: bool,
    user_override: bool,
    screen_suspended: bool,
    suspended_level: Option<u8>,

    previous_global_auto: Option<bool>,
    previous_global_level: Option<u8>,
    previous_sysfs_enable: Option<bool>,
    previous_sysfs_level: Option<u8>,

    lower_candidate: Option<u8>,
    lower_confirmations: u8,

    thermal_paths: ThermalPaths,
    charge_probe: ChargeProbe,
    last_probe_refresh: Instant,
}

impl KurumiFanGovernor {
    fn new() -> Self {
        Self {
            initialization_started: None,
            initialized: false,
            user_override: false,
            screen_suspended: false,
            suspended_level: None,
            previous_global_auto: None,
            previous_global_level: None,
            previous_sysfs_enable: None,
            previous_sysfs_level: None,
            lower_candidate: None,
            lower_confirmations: 0,
            // Construct paths without touching thermal sysfs.  Values are
            // opened only in a runtime mode that actually needs them.
            thermal_paths: ThermalPaths::configured(),
            charge_probe: ChargeProbe::detect(),
            last_probe_refresh: Instant::now(),
        }
    }

    fn reset_for_missing_driver(&mut self) {
        self.initialization_started = None;
        self.initialized = false;
        self.user_override = false;
        self.screen_suspended = false;
        self.suspended_level = None;
        self.previous_global_auto = None;
        self.previous_global_level = None;
        self.previous_sysfs_enable = None;
        self.previous_sysfs_level = None;
        self.reset_lowering();
    }

    fn refresh_charge_probe_if_needed(&mut self) {
        if self.last_probe_refresh.elapsed() < Duration::from_secs(PROBE_REFRESH_SECS) {
            return;
        }
        self.charge_probe = ChargeProbe::detect();
        self.last_probe_refresh = Instant::now();
    }

    fn read_snapshot(&self) -> Option<Snapshot> {
        let sysfs_enable = read_u8(FAN_ENABLE_PATH)? != 0;
        let sysfs_level = valid_level(read_u8(FAN_LEVEL_PATH)?)?;

        let global_auto = match get_global_u8(GLOBAL_FAN_ENABLE).and_then(valid_bool) {
            Some(value) => value,
            None => {
                put_global_u8(GLOBAL_FAN_ENABLE, 1);
                true
            }
        };

        let global_level = match get_global_u8(GLOBAL_FAN_LEVEL).and_then(valid_level) {
            Some(value) => value,
            None => {
                put_global_u8(GLOBAL_FAN_LEVEL, sysfs_level);
                sysfs_level
            }
        };

        Some(Snapshot {
            global_auto,
            global_level,
            sysfs_enable,
            sysfs_level,
        })
    }

    fn remember(&mut self, snapshot: Snapshot) {
        self.previous_global_auto = Some(snapshot.global_auto);
        self.previous_global_level = Some(snapshot.global_level);
        self.previous_sysfs_enable = Some(snapshot.sysfs_enable);
        self.previous_sysfs_level = Some(snapshot.sysfs_level);
    }

    fn remember_current_state(&mut self) {
        if let Some(snapshot) = self.read_snapshot() {
            self.remember(snapshot);
        }
    }

    fn initialization_tick(&mut self, snapshot: Snapshot, context: RuntimeContext) {
        let initialization_complete = self
            .initialization_started
            .get_or_insert_with(Instant::now)
            .elapsed()
            >= Duration::from_secs(INITIALIZATION_SECS);

        if !initialization_complete {
            // Screen-off standby is a power rule, not curve ownership.  It is
            // safe during the synchronization window and never reads a
            // thermal zone.
            if context.should_suspend() {
                if !self.screen_suspended {
                    self.suspended_level = Some(snapshot.global_level);
                }
                self.screen_suspended = true;
                self.force_screen_standby(snapshot.global_auto, snapshot.global_level);
                self.remember_current_state();
            } else {
                self.remember(snapshot);
            }
            return;
        }

        self.initialized = true;
        self.user_override = false;
        self.reset_lowering();

        if context.should_suspend() {
            if !self.screen_suspended {
                self.suspended_level = Some(snapshot.global_level);
            }
            self.screen_suspended = true;
            self.suspended_tick(snapshot);
        } else if snapshot.global_auto {
            self.screen_suspended = false;
            let target = self
                .target_level(context)
                .unwrap_or(snapshot.global_level);
            self.write_owned_state(true, target);
            self.remember_current_state();
        } else {
            self.screen_suspended = false;
            self.write_owned_state(false, snapshot.global_level);
            self.remember_current_state();
        }
    }

    fn tick(&mut self, snapshot: Snapshot, context: RuntimeContext) {
        if context.should_suspend() {
            if !self.screen_suspended {
                self.suspended_level = Some(snapshot.global_level);
            }
            self.screen_suspended = true;
            self.suspended_tick(snapshot);
            return;
        }

        if self.screen_suspended {
            self.resume_from_screen_suspend(snapshot, context);
            return;
        }

        let global_auto_changed = self
            .previous_global_auto
            .map(|old| old != snapshot.global_auto)
            .unwrap_or(false);
        let global_level_changed = self
            .previous_global_level
            .map(|old| old != snapshot.global_level)
            .unwrap_or(false);
        let sysfs_enable_changed = self
            .previous_sysfs_enable
            .map(|old| old != snapshot.sysfs_enable)
            .unwrap_or(false);
        let sysfs_level_changed = self
            .previous_sysfs_level
            .map(|old| old != snapshot.sysfs_level)
            .unwrap_or(false);

        // Settings.Global is the primary UI source.  If it changed, apply it
        // to sysfs before considering a simultaneous sysfs difference.
        if global_auto_changed || global_level_changed {
            self.handle_global_change(
                snapshot,
                global_auto_changed,
                global_level_changed,
                context,
            );
            self.remember_current_state();
            return;
        }

        // A direct sysfs write is also a manual action.  Mirror it back to
        // Settings.Global so both views stay coherent.
        if sysfs_enable_changed || sysfs_level_changed {
            self.handle_sysfs_change(
                snapshot,
                sysfs_enable_changed,
                sysfs_level_changed,
                context,
            );
            self.remember_current_state();
            return;
        }

        // A previous write may have failed or a service may have rewritten one
        // side between polls.  With no newly detected user action, repair the
        // mismatch from the Settings.Global side and retry until it sticks.
        if snapshot.global_auto != snapshot.sysfs_enable
            || snapshot.global_level != snapshot.sysfs_level
        {
            self.write_owned_state(snapshot.global_auto, snapshot.global_level);
            self.remember_current_state();
            return;
        }

        if !snapshot.global_auto {
            self.remember(snapshot);
            return;
        }

        if self.user_override {
            self.remember(snapshot);
            return;
        }

        if let Some(target) = self.target_level(context) {
            self.apply_automatic_target(snapshot.sysfs_level, target);
        }
        self.remember_current_state();
    }

    fn suspended_tick(&mut self, snapshot: Snapshot) {
        let global_auto_changed = self
            .previous_global_auto
            .map(|old| old != snapshot.global_auto)
            .unwrap_or(false);
        let global_level_changed = self
            .previous_global_level
            .map(|old| old != snapshot.global_level)
            .unwrap_or(false);
        let sysfs_enable_changed = self
            .previous_sysfs_enable
            .map(|old| old != snapshot.sysfs_enable)
            .unwrap_or(false);
        let sysfs_level_changed = self
            .previous_sysfs_level
            .map(|old| old != snapshot.sysfs_level)
            .unwrap_or(false);

        self.reset_lowering();

        // The physical driver and Settings.Global are both held at level 0.
        // Manual writes update the saved in-memory resume level, then both
        // public interfaces return to 0 so they never remain desynchronized.
        if global_auto_changed || global_level_changed {
            if global_level_changed {
                self.suspended_level = Some(snapshot.global_level);
            }
            if global_auto_changed && snapshot.global_auto {
                self.user_override = false;
            } else if global_level_changed && snapshot.global_auto {
                self.user_override = true;
            }
            let desired_level = self.suspended_level.unwrap_or(snapshot.global_level);
            self.force_screen_standby(snapshot.global_auto, desired_level);
            self.remember_current_state();
            return;
        }

        if sysfs_enable_changed || sysfs_level_changed {
            let desired_auto = if sysfs_enable_changed {
                put_global_u8(GLOBAL_FAN_ENABLE, u8::from(snapshot.sysfs_enable));
                if snapshot.sysfs_enable {
                    self.user_override = false;
                }
                snapshot.sysfs_enable
            } else {
                snapshot.global_auto
            };

            if sysfs_level_changed {
                self.suspended_level = Some(snapshot.sysfs_level);
                if desired_auto && !sysfs_enable_changed {
                    self.user_override = true;
                }
            }

            let desired_level = self.suspended_level.unwrap_or(snapshot.global_level);
            self.force_screen_standby(desired_auto, desired_level);
            self.remember_current_state();
            return;
        }

        let desired_level = self.suspended_level.unwrap_or(snapshot.global_level);
        self.force_screen_standby(snapshot.global_auto, desired_level);
        self.remember_current_state();
    }

    fn resume_from_screen_suspend(&mut self, snapshot: Snapshot, context: RuntimeContext) {
        self.screen_suspended = false;
        self.reset_lowering();
        let resume_level = self.suspended_level.take().unwrap_or(snapshot.global_level);

        let global_auto_changed = self
            .previous_global_auto
            .map(|old| old != snapshot.global_auto)
            .unwrap_or(false);
        let global_level_changed = self
            .previous_global_level
            .map(|old| old != snapshot.global_level)
            .unwrap_or(false);
        let sysfs_enable_changed = self
            .previous_sysfs_enable
            .map(|old| old != snapshot.sysfs_enable)
            .unwrap_or(false);
        let sysfs_level_changed = self
            .previous_sysfs_level
            .map(|old| old != snapshot.sysfs_level)
            .unwrap_or(false);

        if global_auto_changed || global_level_changed {
            self.handle_global_change(
                snapshot,
                global_auto_changed,
                global_level_changed,
                context,
            );
        } else if sysfs_enable_changed || sysfs_level_changed {
            self.handle_sysfs_change(
                snapshot,
                sysfs_enable_changed,
                sysfs_level_changed,
                context,
            );
        } else if !snapshot.global_auto {
            self.write_owned_state(false, resume_level);
        } else if self.user_override {
            self.write_owned_state(true, resume_level);
        } else {
            let target = self
                .target_level(context)
                .unwrap_or(resume_level);
            self.write_owned_state(true, target);
        }

        self.remember_current_state();
    }

    fn handle_global_change(
        &mut self,
        snapshot: Snapshot,
        auto_changed: bool,
        level_changed: bool,
        context: RuntimeContext,
    ) {
        self.reset_lowering();

        if auto_changed {
            if !snapshot.global_auto {
                // Automatic mode was explicitly disabled.  Preserve the
                // selected level as the driver's backup, but power the fan off.
                self.write_owned_state(false, snapshot.global_level);
                return;
            }

            // A 0 -> 1 transition is the documented manual-override reset.
            self.user_override = false;
            let target = self
                .target_level(context)
                .unwrap_or(snapshot.global_level);
            self.write_owned_state(true, target);
            return;
        }

        if level_changed {
            // Manual speed selected in Nubia Settings.  Apply it first, then
            // yield temperature control until automatic mode is toggled.
            self.write_owned_state(snapshot.global_auto, snapshot.global_level);
            if snapshot.global_auto {
                self.user_override = true;
            }
        }
    }

    fn handle_sysfs_change(
        &mut self,
        snapshot: Snapshot,
        enable_changed: bool,
        level_changed: bool,
        context: RuntimeContext,
    ) {
        self.reset_lowering();

        if enable_changed {
            put_global_u8(GLOBAL_FAN_ENABLE, u8::from(snapshot.sysfs_enable));
            if snapshot.sysfs_enable {
                // Direct 0 -> 1 has the same meaning as re-enabling automatic
                // mode through Nubia Settings.
                self.user_override = false;
                let target = self
                    .target_level(context)
                    .unwrap_or(snapshot.sysfs_level);
                self.write_owned_state(true, target);
            } else if level_changed {
                put_global_u8(GLOBAL_FAN_LEVEL, snapshot.sysfs_level);
            }
            return;
        }

        if level_changed {
            put_global_u8(GLOBAL_FAN_LEVEL, snapshot.sysfs_level);
            if snapshot.global_auto {
                self.user_override = true;
            }
        }
    }

    fn target_level(&self, context: RuntimeContext) -> Option<u8> {
        // With the screen off, charging below 100% is the only mode allowed to
        // read a temperature, and it reads the battery only.
        if !context.screen_on {
            return context
                .charging_effective
                .then(|| self.thermal_paths.battery_temp_mc().map(battery_curve))
                .flatten();
        }

        let soc_level = self.thermal_paths.soc_temp_mc().map(soc_curve);
        if !context.charging_effective {
            return soc_level;
        }

        let battery_level = self.thermal_paths.battery_temp_mc().map(battery_curve);

        match (soc_level, battery_level) {
            (Some(soc), Some(battery)) => Some(soc.max(battery)),
            (Some(soc), None) => Some(soc),
            (None, Some(battery)) => Some(battery),
            (None, None) => None,
        }
    }

    fn force_screen_standby(&self, automatic_enabled: bool, desired_level: u8) {
        if automatic_enabled {
            // Standby is represented identically in Settings.Global and the
            // Nubia sysfs driver.  The previous desired/manual level lives only
            // in memory until the screen policy allows restoration.
            self.write_owned_state(true, 0);
        } else {
            // Automatic mode is already disabled, so preserving its selected
            // level cannot spin the hardware and keeps both interfaces equal.
            self.write_owned_state(false, desired_level);
        }
    }

    fn apply_automatic_target(&mut self, current: u8, target: u8) {
        if target > current {
            self.reset_lowering();
            self.write_owned_state(true, target);
            return;
        }

        if target == current {
            self.reset_lowering();
            return;
        }

        if self.lower_candidate == Some(target) {
            self.lower_confirmations = self.lower_confirmations.saturating_add(1);
        } else {
            self.lower_candidate = Some(target);
            self.lower_confirmations = 1;
        }

        if self.lower_confirmations >= LOWER_CONFIRMATIONS {
            let next = current.saturating_sub(1).max(target);
            self.reset_lowering();
            self.write_owned_state(true, next);
        }
    }

    fn reset_lowering(&mut self) {
        self.lower_candidate = None;
        self.lower_confirmations = 0;
    }

    fn write_owned_state(&self, enable: bool, level: u8) {
        let level = level.min(5);

        if enable {
            // While disabled, fan_speed_level updates the driver's backup.
            // Write it before enable=1 so the driver restores the intended
            // level instead of briefly spinning at an old one.
            write_u8_if_diff(FAN_LEVEL_PATH, level);
            write_u8_if_diff(FAN_ENABLE_PATH, 1);
        } else {
            // Disable first, then update the saved level while hardware stays
            // off.  It will be replaced by the automatic curve on 0 -> 1.
            write_u8_if_diff(FAN_ENABLE_PATH, 0);
            write_u8_if_diff(FAN_LEVEL_PATH, level);
        }

        // Retry once after read-back if the driver's logical enable state did
        // not accept the first write.  A persistent mismatch is repaired by
        // the regular synchronization path on subsequent cycles.
        if read_u8(FAN_ENABLE_PATH).map(|value| value != 0) != Some(enable) {
            write_u8_if_diff(FAN_ENABLE_PATH, u8::from(enable));
        }

        put_global_u8_if_diff(GLOBAL_FAN_ENABLE, u8::from(enable));
        put_global_u8_if_diff(GLOBAL_FAN_LEVEL, level);
    }
}

pub fn spawn_fan_governor(screen_active: Arc<AtomicBool>) {
    let _ = thread::Builder::new()
        .name("kurumi-fan".to_string())
        .spawn(move || fan_governor_loop(screen_active));
}

fn fan_governor_loop(screen_active: Arc<AtomicBool>) {
    let mut governor = KurumiFanGovernor::new();

    loop {
        if !Path::new(FAN_ENABLE_PATH).exists() || !Path::new(FAN_LEVEL_PATH).exists() {
            governor.reset_for_missing_driver();
            thread::sleep(Duration::from_secs(POLL_SECS));
            continue;
        }

        governor.refresh_charge_probe_if_needed();
        let charging = governor.charge_probe.is_charging();
        let battery_below_full = governor
            .charge_probe
            .battery_percent()
            .map(|percent| percent < 100)
            .unwrap_or(true);
        let context = RuntimeContext {
            screen_on: screen_active.load(Ordering::Relaxed),
            charging_effective: charging && battery_below_full,
        };

        if let Some(snapshot) = governor.read_snapshot() {
            if governor.initialized {
                governor.tick(snapshot, context);
            } else {
                governor.initialization_tick(snapshot, context);
            }
        }

        thread::sleep(Duration::from_secs(POLL_SECS));
    }
}

fn soc_curve(temp_mc: i32) -> u8 {
    if temp_mc < 60_000 {
        0
    } else if temp_mc < 65_000 {
        1
    } else if temp_mc < 70_000 {
        2
    } else if temp_mc < 80_000 {
        3
    } else if temp_mc < 90_000 {
        4
    } else {
        5
    }
}

fn battery_curve(temp_mc: i32) -> u8 {
    if temp_mc <= 40_000 {
        0
    } else if temp_mc < 45_000 {
        1
    } else if temp_mc < 50_000 {
        2
    } else if temp_mc < 55_000 {
        3
    } else if temp_mc < 60_000 {
        4
    } else {
        5
    }
}

fn thermal_path(id: u32) -> PathBuf {
    PathBuf::from(format!("/sys/class/thermal/thermal_zone{}/temp", id))
}

fn average_temp_mc(paths: &[PathBuf]) -> Option<i32> {
    let mut sum = 0i64;
    let mut count = 0i64;

    for path in paths {
        if let Some(value) = read_i32(path) {
            sum += i64::from(value);
            count += 1;
        }
    }

    if count == 0 {
        None
    } else {
        Some((sum / count) as i32)
    }
}

fn valid_bool(value: u8) -> Option<bool> {
    match value {
        0 => Some(false),
        1 => Some(true),
        _ => None,
    }
}

fn valid_level(value: u8) -> Option<u8> {
    (value <= 5).then_some(value)
}

fn read_trim<P: AsRef<Path>>(path: P) -> Option<String> {
    fs::read_to_string(path).ok().map(|value| value.trim().to_string())
}

fn read_u8<P: AsRef<Path>>(path: P) -> Option<u8> {
    read_trim(path)?.parse().ok()
}

fn read_i32<P: AsRef<Path>>(path: P) -> Option<i32> {
    read_trim(path)?.parse().ok()
}

fn write_u8_if_diff<P: AsRef<Path>>(path: P, value: u8) -> bool {
    let path = path.as_ref();
    if read_u8(path) == Some(value) {
        return true;
    }
    write_value(path, &value.to_string())
}

fn write_value(path: &Path, value: &str) -> bool {
    if !path.exists() {
        return false;
    }
    if fs::write(path, value).is_ok() {
        return true;
    }

    if let Ok(metadata) = fs::metadata(path) {
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o644);
        let _ = fs::set_permissions(path, permissions);
    }
    fs::write(path, value).is_ok()
}

fn get_global_u8(key: &str) -> Option<u8> {
    let output = Command::new("settings")
        .args(["get", "global", key])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8_lossy(&output.stdout);
    let value = value.trim();
    if value.is_empty() || value.eq_ignore_ascii_case("null") {
        return None;
    }
    value.parse().ok()
}

fn put_global_u8(key: &str, value: u8) {
    let value = value.to_string();
    let _ = Command::new("settings")
        .args(["put", "global", key, &value])
        .output();
}

fn put_global_u8_if_diff(key: &str, value: u8) {
    if get_global_u8(key) != Some(value) {
        put_global_u8(key, value);
    }
}
