#!/system/bin/sh
# Kurumi/Tiro persistent diagnostic logger.
# Manual diagnostic tool; it is NOT installed or started by AnyKernel.
#
# Usage on a rooted phone:
#   sh kurumi_device_panic_logger.sh start
#   sh kurumi_device_panic_logger.sh status
#   sh kurumi_device_panic_logger.sh stop
#   sh kurumi_device_panic_logger.sh postpanic
#
# Logs live under /data/local/tmp/kurumi-debug. logcat and telemetry are rotated.

BASE=${KURUMI_LOG_BASE:-/data/local/tmp/kurumi-debug}
PIDFILE="$BASE/logger.pid"
SELF="$0"

mkdir -p "$BASE" 2>/dev/null

alive() {
    [ -f "$PIDFILE" ] || return 1
    p="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

rotate_file() {
    f="$1"
    max="$2"
    [ -f "$f" ] || return 0
    sz="$(wc -c < "$f" 2>/dev/null)"
    [ -n "$sz" ] || sz=0
    [ "$sz" -lt "$max" ] && return 0
    rm -f "$f.4"
    [ -f "$f.3" ] && mv -f "$f.3" "$f.4"
    [ -f "$f.2" ] && mv -f "$f.2" "$f.3"
    [ -f "$f.1" ] && mv -f "$f.1" "$f.2"
    mv -f "$f" "$f.1"
}

snapshot_common() {
    d="$1"
    mkdir -p "$d"
    uname -a > "$d/uname.txt" 2>&1
    cat /proc/version > "$d/proc-version.txt" 2>&1
    cat /proc/cmdline > "$d/cmdline.txt" 2>&1
    cat /proc/bootconfig > "$d/bootconfig.txt" 2>&1
    getprop > "$d/getprop.txt" 2>&1
    getprop ro.boot.bootreason > "$d/bootreason.txt" 2>&1
    cat /proc/sys/kernel/random/boot_id > "$d/boot-id.txt" 2>&1
    if [ -f /proc/config.gz ]; then
        cp /proc/config.gz "$d/" 2>/dev/null
    fi
}

run_logger() {
    BOOT="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
    [ -n "$BOOT" ] || BOOT=unknown
    STAMP="$(date +%Y%m%d-%H%M%S)"
    DIR="$BASE/live-$STAMP-$BOOT"
    mkdir -p "$DIR/pstore-start"
    echo "$$" > "$PIDFILE"
    echo "$DIR" > "$BASE/current-dir.txt"
    snapshot_common "$DIR"
    cp -a /sys/fs/pstore/* "$DIR/pstore-start/" 2>/dev/null

    LOGCAT_PID=""
    DMESG_PID=""
    cleanup() {
        [ -n "$LOGCAT_PID" ] && kill "$LOGCAT_PID" 2>/dev/null
        [ -n "$DMESG_PID" ] && kill "$DMESG_PID" 2>/dev/null
        rm -f "$PIDFILE"
    }
    trap cleanup EXIT INT TERM HUP

    # Android logger has native file rotation.
    logcat -b all -v threadtime -f "$DIR/logcat.txt" -r 16384 -n 8 >/dev/null 2>&1 &
    LOGCAT_PID=$!

    # Keep the live kernel stream, but bound disk use by restarting it after
    # rotation. `dmesg -w` may replay the current ring after restart; duplicate
    # lines are preferable to an unbounded file during a multi-day panic hunt.
    start_dmesg() {
        dmesg -w > "$DIR/dmesg-live.txt" 2>&1 &
        DMESG_PID=$!
    }
    start_dmesg

    tick=0
    while true; do
        TS="$(date '+%Y-%m-%d %H:%M:%S')"
        TELE="$DIR/telemetry.txt"
        SLOW="$DIR/slow-state.txt"
        rotate_file "$TELE" 16777216
        {
            echo "===== $TS ====="
            echo "uptime=$(cat /proc/uptime 2>/dev/null)"
            echo "load=$(cat /proc/loadavg 2>/dev/null)"
            grep -E 'MemAvailable|MemFree|SwapFree|Slab|SUnreclaim' /proc/meminfo 2>/dev/null
            for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
                [ -f "$f" ] && { echo "--- $f"; cat "$f"; }
            done
            echo "cpu_online=$(cat /sys/devices/system/cpu/online 2>/dev/null)"
            for p in /sys/devices/system/cpu/cpufreq/policy*; do
                [ -d "$p" ] || continue
                printf '%s cur=%s min=%s max=%s gov=%s\n' \
                    "$(basename "$p")" \
                    "$(cat "$p/scaling_cur_freq" 2>/dev/null)" \
                    "$(cat "$p/scaling_min_freq" 2>/dev/null)" \
                    "$(cat "$p/scaling_max_freq" 2>/dev/null)" \
                    "$(cat "$p/scaling_governor" 2>/dev/null)"
            done
            KGSL=/sys/class/kgsl/kgsl-3d0
            [ -e "$KGSL/devfreq/cur_freq" ] && \
                echo "gpu cur=$(cat "$KGSL/devfreq/cur_freq" 2>/dev/null) min=$(cat "$KGSL/devfreq/min_freq" 2>/dev/null) max=$(cat "$KGSL/devfreq/max_freq" 2>/dev/null)"
            echo "--- thermal zones"
            for z in /sys/class/thermal/thermal_zone*; do
                [ -e "$z/type" ] || continue
                printf '%s %s temp=%s mode=%s\n' \
                    "$(basename "$z")" "$(cat "$z/type" 2>/dev/null)" \
                    "$(cat "$z/temp" 2>/dev/null)" "$(cat "$z/mode" 2>/dev/null)"
            done
            echo "--- performance cooling devices"
            for c in /sys/class/thermal/cooling_device*; do
                [ -e "$c/type" ] || continue
                T="$(cat "$c/type" 2>/dev/null)"
                case "$T" in
                    *cpufreq*|*cpu-hotplug*|*cpu-isolate*|*pause-cpu*|*thermal-pause*|*cluster*|*kgsl*|gpu|display-fps)
                        printf '%s %s cur=%s max=%s\n' \
                            "$(basename "$c")" "$T" \
                            "$(cat "$c/cur_state" 2>/dev/null)" \
                            "$(cat "$c/max_state" 2>/dev/null)"
                        ;;
                esac
            done
        } >> "$TELE" 2>&1

        # Keep a very small last-known-state breadcrumb in persistent pmsg.
        if [ -w /dev/pmsg0 ]; then
            printf 'KURUMI %s uptime=%s load=%s mem=%s\n' \
                "$TS" "$(cut -d' ' -f1 /proc/uptime 2>/dev/null)" \
                "$(cat /proc/loadavg 2>/dev/null)" \
                "$(grep MemAvailable /proc/meminfo 2>/dev/null | tr -s ' ')" \
                > /dev/pmsg0 2>/dev/null
        fi

        tick=$((tick + 1))
        if [ $((tick % 6)) -eq 0 ]; then
            # Rotate/restart the live dmesg writer if it reached 16 MiB.
            if [ -f "$DIR/dmesg-live.txt" ]; then
                dsz="$(wc -c < "$DIR/dmesg-live.txt" 2>/dev/null)"
                [ -n "$dsz" ] || dsz=0
                if [ "$dsz" -ge 16777216 ]; then
                    [ -n "$DMESG_PID" ] && kill "$DMESG_PID" 2>/dev/null
                    wait "$DMESG_PID" 2>/dev/null
                    DMESG_PID=""
                    rotate_file "$DIR/dmesg-live.txt" 16777216
                    start_dmesg
                fi
            fi

            rotate_file "$SLOW" 16777216
            {
                echo "===== $TS ====="
                echo "### INTERRUPTS"; cat /proc/interrupts 2>/dev/null
                echo "### SOFTIRQS"; cat /proc/softirqs 2>/dev/null
                echo "### VMSTAT"; cat /proc/vmstat 2>/dev/null
                echo "### DISKSTATS"; cat /proc/diskstats 2>/dev/null
                echo "### WAKEUP"; cat /sys/kernel/debug/wakeup_sources 2>/dev/null
            } >> "$SLOW" 2>&1
        fi
        sleep 5
    done
}

case "${1:-status}" in
    start)
        if alive; then
            echo "Kurumi logger already running: pid $(cat "$PIDFILE")"
            exit 0
        fi
        nohup sh "$SELF" run >/dev/null 2>&1 &
        sleep 1
        if alive; then
            echo "Kurumi logger started: pid $(cat "$PIDFILE")"
            cat "$BASE/current-dir.txt" 2>/dev/null
        else
            echo "ERROR: logger did not start" >&2
            exit 1
        fi
        ;;
    run)
        run_logger
        ;;
    stop)
        if alive; then
            p="$(cat "$PIDFILE")"
            kill "$p" 2>/dev/null
            echo "Kurumi logger stop requested: pid $p"
        else
            rm -f "$PIDFILE"
            echo "Kurumi logger is not running"
        fi
        ;;
    status)
        if alive; then
            echo "running pid=$(cat "$PIDFILE") dir=$(cat "$BASE/current-dir.txt" 2>/dev/null)"
        else
            echo "stopped"
        fi
        ;;
    postpanic)
        STAMP="$(date +%Y%m%d-%H%M%S)"
        D="$BASE/post-panic-$STAMP"
        mkdir -p "$D/pstore"
        snapshot_common "$D"
        cp -a /sys/fs/pstore/* "$D/pstore/" 2>/dev/null
        dmesg > "$D/dmesg-after-reboot.txt" 2>&1
        logcat -b all -d -v threadtime > "$D/logcat-after-reboot.txt" 2>&1
        echo "post-panic snapshot: $D"
        ;;
    *)
        echo "usage: $0 {start|stop|status|postpanic|run}" >&2
        exit 2
        ;;
esac
