#!/system/bin/sh
#
# kurumi_collect_logs.sh - one-shot diagnostic bundle collector (RedMagic 9 Pro / SM8650).
# Run as ROOT right after the phone recovers from a crashdump / memorydump:
#
#   su -c sh /data/local/tmp/kurumi_collect_logs.sh
#
# Output: /sdcard/kurumi-logs-<timestamp>.tar.gz
#
# Everything is read-only except the output dir. Nothing is cleaned or reset.

OUT_BASE=/sdcard
STAMP="$(date +%Y%m%d-%H%M%S)"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8)"
[ -n "$BOOT_ID" ] || BOOT_ID=unknown
D="$OUT_BASE/kurumi-logs-$STAMP-$BOOT_ID"
TAR="$D.tar.gz"

mkdir -p "$D" || { echo "ERROR: cannot create $D" >&2; exit 1; }
cd "$D" || exit 1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

section() {
    S="$D/$1"
    mkdir -p "$S"
}

# ---------- 0. identity ----------
section identity
{
    echo "### date";        date
    echo "### uname";       uname -a
    echo "### proc version"; cat /proc/version
    echo "### uptime";      cat /proc/uptime
    echo "### cmdline";     cat /proc/cmdline
    echo "### bootconfig";  cat /proc/bootconfig 2>/dev/null
    echo "### boot_id";     cat /proc/sys/kernel/random/boot_id
} > identity/system.txt 2>&1

getprop > identity/getprop.txt 2>&1
getprop ro.boot.bootreason > identity/bootreason.txt 2>&1
# Every boot-reason related property (Qualcomm exposes several)
getprop | grep -iE 'boot.?reason|resetreason|dload|dump|crash' > identity/bootreason-props.txt 2>&1

if [ -f /proc/config.gz ]; then
    cp /proc/config.gz identity/ 2>/dev/null
fi

# ---------- 1. pstore (MOST IMPORTANT - last panic) ----------
section pstore
if [ -d /sys/fs/pstore ]; then
    ls -la /sys/fs/pstore > pstore/listing.txt 2>&1
    # Copy contents AND keep raw permissions/names for reference
    for f in /sys/fs/pstore/*; do
        [ -e "$f" ] || continue
        b="$(basename "$f")"
        cp "$f" "pstore/$b" 2>/dev/null
        # permissions may block plain cp; try dd
        [ -s "pstore/$b" ] || dd if="$f" of="pstore/$b" 2>/dev/null
    done
    log "pstore: $(ls pstore | grep -v listing | wc -l) files"
else
    echo "no /sys/fs/pstore" > pstore/MISSING.txt
fi

# ---------- 2. kernel logs after reboot ----------
section kernel
dmesg > kernel/dmesg.txt 2>&1
dmesg -T > kernel/dmesg-human.txt 2>/dev/null
cat /proc/last_kmsg > kernel/last_kmsg.txt 2>/dev/null
# console-ramoops may also appear here on some builds
ls -la /sys/fs/consolelog > kernel/consolelog.txt 2>&1
cp -a /sys/fs/consolelog/* kernel/ 2>/dev/null

# ---------- 3. logcat ----------
section logcat
logcat -b all -d -v threadtime > logcat/all.txt 2>&1
logcat -b crash -d -v threadtime > logcat/crash.txt 2>&1
logcat -b events -d > logcat/events.txt 2>&1
logcat -b system -d > logcat/system.txt 2>&1
logcat -b kernel -d > logcat/kernel-buffer.txt 2>&1

# ---------- 4. Qualcomm specifics ----------
section qcom
# Subsystem restart / SSR logs
for p in /sys/kernel/ipc_logging /proc/ipc_logging; do
    [ -e "$p" ] && cp -a "$p" qcom/ 2>/dev/null
done

# Ramdump directories (Qualcomm crash dumps land here)
for rd in /data/vendor/ramdumps /data/vendor/log /data/log /sdcard/log; do
    if [ -d "$rd" ]; then
        mkdir -p "qcom/$(echo "$rd" | sed 's|/|_|g')"
        # copy only files modified in the last 3 days to bound size
        find "$rd" -maxdepth 2 -type f -mtime -3 -exec cp {} "qcom/$(echo "$rd" | sed 's|/|_|g')/" \; 2>/dev/null
    fi
done

# Modem / ADSP / SLPI subsystem states
for s in /sys/bus/msm_subsys/devices/*; do
    [ -e "$s/name" ] || continue
    echo "$(basename $s): name=$(cat $s/name) state=$(cat $s/state 2>/dev/null)" >> qcom/subsys.txt
done

#---------- 5. tombstones / ANR / dropbox ----------
section android
mkdir -p android/tombstones android/dropbox
# tombstones from last 3 days only (they accumulate)
find /data/tombstones -type f -mtime -3 -exec cp {} android/tombstones/ \; 2>/dev/null
ls -la /data/tombstones > android/tombstones-listing.txt 2>&1

# ANR traces
mkdir -p android/anr
find /data/anr -type f -mtime -3 -exec cp {} android/anr/ \; 2>/dev/null

# dropbox (system crash reporter), recent entries
if [ -d /data/system/dropbox ]; then
    ls -lat /data/system/dropbox | head -50 > android/dropbox/listing.txt 2>&1
    # newest 30 files, up to ~20MB total
    total=0
    for f in $(ls -t /data/system/dropbox 2>/dev/null | head -30); do
        sz=$(stat -c%s "/data/system/dropbox/$f" 2>/dev/null || echo 0)
        total=$((total + sz))
        [ $total -gt 20971520 ] && break
        cp "/data/system/dropbox/$f" android/dropbox/ 2>/dev/null
    done
fi

# battery/health history (uptime resets, unexpected shutdowns)
dumpsys batterystats --charging > android/batterystats.txt 2>&1
dumpsys battery > android/battery.txt 2>&1
dumpsys power > android/power.txt 2>&1
dumpsys thermal > android/thermal-service.txt 2>&1

# ---------- 6. hardware state at capture time ----------
section hw
cat /proc/interrupts > hw/interrupts.txt 2>&1
cat /proc/meminfo > hw/meminfo.txt 2>&1
cat /proc/vmstat > hw/vmstat.txt 2>&1
cat /proc/slabinfo > hw/slabinfo.txt 2>&1
cat /proc/buddyinfo > hw/buddyinfo.txt 2>&1
cat /proc/pagetypeinfo > hw/pagetypeinfo.txt 2>&1
cat /proc/diskstats > hw/diskstats.txt 2>&1
cat /proc/pressure/cpu > hw/psi-cpu.txt 2>&1
cat /proc/pressure/memory > hw/psi-mem.txt 2>&1
cat /proc/pressure/io > hw/psi-io.txt 2>&1
cat /sys/kernel/debug/wakeup_sources > hw/wakeup_sources.txt 2>&1

# thermal zones + cooling devices
{
    echo "### thermal zones"
    for z in /sys/class/thermal/thermal_zone*; do
        [ -e "$z/type" ] || continue
        echo "$(basename $z) type=$(cat $z/type) temp=$(cat $z/temp 2>/dev/null)"
    done
    echo "### cooling devices"
    for c in /sys/class/thermal/cooling_device*; do
        [ -e "$c/type" ] || continue
        echo "$(basename $c) type=$(cat $c/type) cur=$(cat $c/cur_state 2>/dev/null) max=$(cat $c/max_state 2>/dev/null)"
    done
} > hw/thermal.txt 2>&1

# CPU policy snapshot
{
    echo "online: $(cat /sys/devices/system/cpu/online)"
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] || continue
        echo "$(basename $p) cur=$(cat $p/scaling_cur_freq 2>/dev/null) min=$(cat $p/scaling_min_freq 2>/dev/null) max=$(cat $p/scaling_max_freq 2>/dev/null) hw_min=$(cat $p/cpuinfo_min_freq 2>/dev/null) hw_max=$(cat $p/cpuinfo_max_freq 2>/dev/null)"
    done
} > hw/cpufreq.txt 2>&1

# GPU
cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq > hw/gpu.txt 2>&1
cat /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies >> hw/gpu.txt 2>&1
cat /sys/class/kgsl/kgsl-3d0/gpuclk >> hw/gpu.txt 2>&1

# Kurumi screen-state bridge (if this kernel is installed)
if [ -d /sys/kernel/kurumi_screen ]; then
    {
        echo "state=$(cat /sys/kernel/kurumi_screen/state)"
        echo "seq=$(cat /sys/kernel/kurumi_screen/seq)"
        echo "since_ms=$(cat /sys/kernel/kurumi_screen/since_ms)"
    } > hw/kurumi-screen.txt 2>&1
fi

# UFS health
for u in /sys/devices/platform/soc/1d84000.ufshc /sys/bus/platform/devices/1d84000.ufshc; do
    if [ -d "$u" ]; then
        for a in clkgate_enable clkscale_enable monitor_urgent_enable read_ahead_kb; do
            echo "$a=$(cat $u/$a 2>/dev/null)"
        done > hw/ufs.txt
        break
    fi
done
# UFS error counters if exposed
for f in /sys/kernel/debug/ufshc0/err_state /sys/bus/platform/devices/*.ufshc/*err*; do
    [ -e "$f" ] && { echo "--- $f"; cat "$f"; } >> hw/ufs.txt 2>/dev/null
done

# eMMC/UFS health via /sys/block
for b in /sys/block/sda /sys/block/sde /sys/block/sdf; do
    [ -d "$b" ] || continue
    echo "--- $b" >> hw/storage.txt
    cat "$b/queue/read_ahead_kb" >> hw/storage.txt 2>/dev/null
    cat "$b/stat" >> hw/storage.txt 2>/dev/null
done

#---------- 7. module & module parameter state ----------
section modules
cat /proc/modules > modules/proc-modules.txt 2>&1
lsmod > modules/lsmod.txt 2>/dev/null
# sched_walt params (kurumi knobs)
for m in /sys/module/sched_walt/parameters/* /sys/module/*/parameters/kurumi_*; do
    [ -e "$m" ] || continue
    echo "$m = $(cat "$m" 2>/dev/null)"
done > modules/params.txt 2>&1

# ---------- 8. recent file timestamps around last boot ----------
section misc
stat /data/misc/recovery 2>/dev/null > misc/recovery-stat.txt
ls -la /data/misc/recovery > misc/recovery-ls.txt 2>&1
# persistent log from kurumi_device_panic_logger.sh, if it was running
if [ -d /data/local/tmp/kurumi-debug ]; then
    log "copying kurumi-debug persistent logs"
    mkdir -p misc/kurumi-debug
    # only live-*/post-panic-* dirs, newest 2 of each, newest telemetry
    for d in $(ls -dt /data/local/tmp/kurumi-debug/post-panic-* 2>/dev/null | head -2) \
             $(ls -dt /data/local/tmp/kurumi-debug/live-* 2>/dev/null | head -2); do
        [ -d "$d" ] || continue
        b="misc/kurumi-debug/$(basename "$d")"
        mkdir -p "$b"
        # take the newest of each rotated file, skip the huge rotated history
        for f in "$d"/*.txt; do
            [ -f "$f" ] && tail -c 4194304 "$f" > "$b/$(basename "$f")" 2>/dev/null
        done
        [ -d "$d/pstore" ] && cp -a "$d/pstore" "$b/" 2>/dev/null
        [ -d "$d/pstore-start" ] && cp -a "$d/pstore-start" "$b/" 2>/dev/null
    done
fi

# watchdog info
cat /proc/sys/kernel/hung_task_timeout_secs > misc/hung-task.txt 2>&1
ls -la /sys/module/msm_poweroff /sys/module/qcom_watchdog* > misc/watchdog.txt 2>&1
cat /sys/module/msm_poweroff/parameters/* >> misc/watchdog.txt 2>/dev/null

# ---------- 9. package archive ----------
log "packing..."
tar -czf "$TAR" -C "$OUT_BASE" "$(basename "$D")" 2>/dev/null
SZ=$(stat -c%s "$TAR" 2>/dev/null || du -b "$TAR" 2>/dev/null | cut -f1)
log "done: $TAR ($(( ${SZ:-0} / 1024 )) KB)"
echo
echo "==================================================================="
echo " Bundle: $TAR"
echo " Pull to PC:  adb pull $TAR"
echo " If a NEW crashdump just happened, the key files are:"
echo "   pstore/dmesg-ramoops-*   <- kernel panic backtrace"
echo "   identity/bootreason.txt  <- why the device reset"
echo "==================================================================="
