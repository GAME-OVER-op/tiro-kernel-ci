#!/system/bin/sh
# =====================================================================
# Kurumi: enable modem remoteproc SSR recovery on Nubia SM8650 (tiro).
#
# Why: the Nubia kernel hardcodes recovery_disabled=true for every PAS
# remoteproc (drivers/remoteproc/qcom_q6v5_pas.c:1832). A modem firmware
# fatal error then panics the WHOLE device into Qualcomm CrashDump instead
# of restarting the modem ("rproc recovery state: disabled and lead to
# device crash"). Observed in the wild:
#   lte_rrc_plmn_search.c:9211:Assert search_req_ptr->plmn_rat_list.length > 0 failed
# With recovery enabled the same event becomes a short modem SSR restart.
#
# The remoteproc core is built into the GKI Image (CONFIG_REMOTEPROC=y),
# so this runtime sysfs switch works regardless of the vendor module that
# provides the driver. The PAS driver keeps its internal cache in sync via
# the android_vh_rproc_recovery_set vendor hook.
#
# Install as a persistent boot script (Magisk/KernelSU both run service.d):
#   adb push kurumi_enable_modem_recovery.sh /data/adb/service.d/
#   adb shell su -c chmod 755 /data/adb/service.d/kurumi_enable_modem_recovery.sh
# Run manually:
#   adb shell su -c sh /data/adb/service.d/kurumi_enable_modem_recovery.sh
# Revert:
#   su -c 'echo disabled > /sys/class/remoteproc/remoteprocN/recovery'
#   (N = the remoteproc whose name contains remoteproc-mss)
# =====================================================================

for r in /sys/class/remoteproc/remoteproc*; do
    [ -e "$r/name" ] || continue
    n="$(cat "$r/name" 2>/dev/null)"
    case "$n" in
        *remoteproc-mss*)
            cur="$(cat "$r/recovery" 2>/dev/null)"
            if [ "$cur" = "enabled" ]; then
                echo "$n: recovery already enabled"
            else
                chmod 0644 "$r/recovery" 2>/dev/null
                if echo enabled > "$r/recovery" 2>/dev/null; then
                    echo "$n: recovery ENABLED"
                else
                    echo "$n: FAILED to enable (cur=$cur)"
                fi
            fi
            ;;
        *)
            echo "$n: unchanged (recovery=$(cat "$r/recovery" 2>/dev/null))"
            ;;
    esac
done
