#
# Kurumi Kernel - interactive flash-time menu (getevent / keycheck driven)
# Sourced by anykernel.sh AFTER tools/ak3-core.sh so ui_print/$bin/abort exist.
# Exports: KROM, KGPU, KROOT, KPROFILE, KFAN, KDAEMON_VARIANT and KSELINUX.
#
# Unified key model ($FUNCTION returns 0 for Vol Up, 1 for Vol Down):
#   Vol Down = move the '>' cursor | Vol Up = select the pointed item
#

ui_print " ";
ui_print "==============================";
ui_print " Kurumi Kernel installer";
ui_print "==============================";

# ---- key detection: getevent if the recovery exposes it, else keycheck ----
keytest() {
  ui_print " " "   Press a Vol key to begin...";
  (/system/bin/getevent -lc 1 2>&1 | /system/bin/grep VOLUME | /system/bin/grep " DOWN" > "$home/kurumi_events") || return 1;
  return 0;
}

chooseport() {
  while true; do
    /system/bin/getevent -lc 1 2>&1 | /system/bin/grep VOLUME | /system/bin/grep " DOWN" > "$home/kurumi_events";
    if cat "$home/kurumi_events" 2>/dev/null | /system/bin/grep VOLUME >/dev/null; then
      break;
    fi;
  done;
  if cat "$home/kurumi_events" 2>/dev/null | /system/bin/grep VOLUMEUP >/dev/null; then
    return 0;
  fi;
  return 1;
}

chooseportold() {
  # First call clears any previous input; the second reads the real keypress.
  $bin/keycheck;
  $bin/keycheck;
  SEL=$?;
  if [ "$1" = "UP" ]; then
    UP=$SEL;
  elif [ "$1" = "DOWN" ]; then
    DOWN=$SEL;
  elif [ "$SEL" -eq "$UP" ]; then
    return 0;
  elif [ "$SEL" -eq "$DOWN" ]; then
    return 1;
  else
    abort "   Vol key not detected!";
  fi;
}

if keytest; then
  FUNCTION=chooseport;
else
  FUNCTION=chooseportold;
  ui_print " " "   Press Vol Up...";
  $FUNCTION "UP";
  ui_print "   Press Vol Down...";
  $FUNCTION "DOWN";
fi;

kurumi_kernel_label() {
  case "$KR_IDX" in
    1) KERNEL_LABEL="KernelSU";;
    2) KERNEL_LABEL="KernelSU + SuSFS";;
    *) KERNEL_LABEL="Stock (no root)";;
  esac;
}

kurumi_profile_label() {
  case "$KP_IDX" in
    0) PROFILE_LABEL="Economy";;
    2) PROFILE_LABEL="Full";;
    3) PROFILE_LABEL="Do not install";;
    *) PROFILE_LABEL="Balance";;
  esac;
}

kurumi_voltage_label() {
  case "$KV_IDX" in
    0) VOLTAGE_LABEL="Low voltage";;
    2) VOLTAGE_LABEL="High voltage";;
    *) VOLTAGE_LABEL="Balanced";;
  esac;
}

kurumi_cursor_line() {
  if [ "$1" -eq "$2" ]; then
    ui_print " > $3";
  else
    ui_print "   $3";
  fi;
}

kurumi_print_controls() {
  ui_print "   Vol Down = move cursor";
  ui_print "   Vol Up   = select";
  ui_print " ";
}

kurumi_render_firmware() {
  kurumi_cursor_line "$KROM_IDX" 0 "RedMagic OS (Stock)";
  kurumi_cursor_line "$KROM_IDX" 1 "LineageOS (Custom)";
}

kurumi_render_kernel() {
  kurumi_cursor_line "$KR_IDX" 0 "Stock        - no root";
  [ -f "$home/files/image/kurumi_ksu" ] && kurumi_cursor_line "$KR_IDX" 1 "KernelSU     - root";
  [ -f "$home/files/image/kurumi_ksu_susfs" ] && kurumi_cursor_line "$KR_IDX" 2 "KSU + SuSFS  - root + SuSFS";
  return 0;
}

kurumi_render_profile() {
  kurumi_cursor_line "$KP_IDX" 0 "Economy - maximum power saving";
  kurumi_cursor_line "$KP_IDX" 1 "Balance - balanced operation";
  kurumi_cursor_line "$KP_IDX" 2 "Full    - no Kurumi CPU limits";
  kurumi_cursor_line "$KP_IDX" 3 "Skip    - do not install daemon";
}

kurumi_render_cooler() {
  kurumi_cursor_line "$KFAN_IDX" 0 "Keep stock/manual control";
  kurumi_cursor_line "$KFAN_IDX" 1 "Enable automatic Kurumi control";
}

kurumi_render_gpu_dtb() {
  kurumi_cursor_line "$KGPU_IDX" 0 "Stock GPU DTB";
  kurumi_cursor_line "$KGPU_IDX" 1 "Kurumi GPU table";
}

kurumi_render_voltage() {
  kurumi_cursor_line "$KV_IDX" 0 "Low voltage";
  kurumi_cursor_line "$KV_IDX" 1 "Balanced";
  kurumi_cursor_line "$KV_IDX" 2 "High voltage";
}

kurumi_render_selinux() {
  kurumi_cursor_line "$KSELINUX_IDX" 0 "Enforcing (recommended)";
  kurumi_cursor_line "$KSELINUX_IDX" 1 "Permissive";
}

kurumi_render_confirmation() {
  kurumi_cursor_line "$KCONFIRM_IDX" 0 "Confirm and install";
  kurumi_cursor_line "$KCONFIRM_IDX" 1 "Choose again";
}

# No partition is written until the user confirms the complete summary.
while true; do
  KROM="";
  KGPU=skip;
  KROOT=stock;
  KPROFILE=skip;
  KFAN=disabled;
  KDAEMON_VARIANT="";
  KDAEMON_REASON=user_skip;
  KSELINUX=enforcing;

  # ---- 1) Installed firmware ----
  ui_print " ";
  ui_print "------------------------------";
  ui_print " Installed firmware";
  kurumi_print_controls;
  KROM_IDX=0;
  kurumi_render_firmware;
  while true; do
    if $FUNCTION; then
      break;
    fi;
    KROM_IDX=$((KROM_IDX + 1));
    [ "$KROM_IDX" -gt 1 ] && KROM_IDX=0;
    ui_print " ";
    kurumi_render_firmware;
  done;
  ui_print "------------------------------";
  if [ "$KROM_IDX" -eq 0 ]; then
    KROM=redmagic;
    KGPU=skip;
    ROM_LABEL="RedMagic OS";
    ui_print " " "   Selected: RedMagic OS";
  else
    KROM=lineage;
    ROM_LABEL="LineageOS";
    ui_print " " "   Selected: LineageOS";
  fi;

  # ---- 2) Kernel variant ----
  ui_print " ";
  ui_print "------------------------------";
  ui_print " Kernel variant";
  kurumi_print_controls;
  KR_IDX=0;
  kurumi_render_kernel;
  while true; do
    if $FUNCTION; then
      break;
    fi;
    KR_IDX=$((KR_IDX + 1));
    while true; do
      [ "$KR_IDX" -gt 2 ] && KR_IDX=0;
      [ "$KR_IDX" -eq 0 ] && break;
      [ "$KR_IDX" -eq 1 ] && [ -f "$home/files/image/kurumi_ksu" ] && break;
      [ "$KR_IDX" -eq 2 ] && [ -f "$home/files/image/kurumi_ksu_susfs" ] && break;
      KR_IDX=$((KR_IDX + 1));
    done;
    ui_print " ";
    kurumi_render_kernel;
  done;
  ui_print "------------------------------";
  kurumi_kernel_label;
  case "$KR_IDX" in
    1) KROOT=ksu;;
    2) KROOT=susfs;;
    *) KROOT=stock;;
  esac;
  ui_print " " "   Selected: $KERNEL_LABEL";

  # ---- 3) Kurumi runtime profile ----
  KDAEMON_AVAILABLE=1;
  if [ "$KROOT" = "stock" ]; then
    ui_print " ";
    ui_print "------------------------------";
    ui_print " Checking Magisk for Stock kernel";
    ui_print "   Read-only check; no partition writes";
    ui_print "------------------------------";
    if kurumi_probe_magisk_early; then
      ui_print " " "   Magisk found";
      ui_print "   Kurumi daemon can use overlay.d";
    else
      KDAEMON_AVAILABLE=0;
      KDAEMON_REASON=no_magisk;
      ui_print " " "   Magisk not found";
      ui_print "   Kurumi daemon is unavailable";
      ui_print "   with the Stock kernel";
    fi;
  fi;

  if [ "$KDAEMON_AVAILABLE" = "1" ]; then
    ui_print " ";
    ui_print "------------------------------";
    ui_print " Kurumi runtime profile";
    kurumi_print_controls;
    KP_IDX=1;
    kurumi_render_profile;
    while true; do
      if $FUNCTION; then
        break;
      fi;
      KP_IDX=$((KP_IDX + 1));
      [ "$KP_IDX" -gt 3 ] && KP_IDX=0;
      ui_print " ";
      kurumi_render_profile;
    done;
    ui_print "------------------------------";
    kurumi_profile_label;
    case "$KP_IDX" in
      0) KPROFILE=eco;;
      1) KPROFILE=balance;;
      2) KPROFILE=full;;
      *) KPROFILE=skip;;
    esac;
    [ "$KPROFILE" = "skip" ] || KDAEMON_REASON=selected;
    ui_print " " "   Selected: $PROFILE_LABEL";
  fi;

  # ---- 4) Optional cooler-aware daemon binary ----
  if [ "$KPROFILE" != "skip" ]; then
    ui_print " ";
    ui_print "------------------------------";
    ui_print " Kurumi automatic cooler control";
    ui_print " ";
    ui_print "   Uses the stock Nubia fan driver.";
    ui_print "   Automatically selects fan speed";
    ui_print "   from CPU, GPU and battery heat.";
    ui_print "   Screen and charging state are";
    ui_print "   considered to reduce wakeups.";
    ui_print "   A manual speed change pauses the";
    ui_print "   temperature curve until automatic";
    ui_print "   mode is switched off and on again.";
    ui_print " ";
    kurumi_print_controls;
    KFAN_IDX=0;
    kurumi_render_cooler;
    while true; do
      if $FUNCTION; then
        break;
      fi;
      KFAN_IDX=$((KFAN_IDX + 1));
      [ "$KFAN_IDX" -gt 1 ] && KFAN_IDX=0;
      ui_print " ";
      kurumi_render_cooler;
    done;
    ui_print "------------------------------";
    if [ "$KFAN_IDX" -eq 0 ]; then
      KFAN=disabled;
      ui_print " " "   Selected: stock/manual control";
    else
      KFAN=enabled;
      ui_print " " "   Selected: automatic control";
    fi;
  fi;

  # ---- 5) LineageOS GPU DTB ----
  if [ "$KROM" = "lineage" ]; then
    ui_print " ";
    ui_print "------------------------------";
    ui_print " GPU DTB for LineageOS";
    kurumi_print_controls;
    KGPU_IDX=0;
    kurumi_render_gpu_dtb;
    while true; do
      if $FUNCTION; then
        break;
      fi;
      KGPU_IDX=$((KGPU_IDX + 1));
      [ "$KGPU_IDX" -gt 1 ] && KGPU_IDX=0;
      ui_print " ";
      kurumi_render_gpu_dtb;
    done;
    ui_print "------------------------------";
    if [ "$KGPU_IDX" -eq 1 ]; then
      ui_print " " "   Selected: Kurumi GPU table";

      # ---- 6) Kurumi GPU voltage profile ----
      ui_print " ";
      ui_print "------------------------------";
      ui_print " Kurumi GPU voltage profile";
      kurumi_print_controls;
      KV_IDX=1;
      kurumi_render_voltage;
      while true; do
        if $FUNCTION; then
          break;
        fi;
        KV_IDX=$((KV_IDX + 1));
        [ "$KV_IDX" -gt 2 ] && KV_IDX=0;
        ui_print " ";
        kurumi_render_voltage;
      done;
      ui_print "------------------------------";
      kurumi_voltage_label;
      case "$KV_IDX" in
        0) KGPU=kurumi_low;;
        2) KGPU=kurumi_high;;
        *) KGPU=kurumi_balanced;;
      esac;
      ui_print " " "   Selected: $VOLTAGE_LABEL";
    else
      KGPU=stock;
      ui_print " " "   Selected: Stock GPU DTB";
    fi;
  fi;

  # ---- 7) SELinux mode ----
  ui_print " ";
  ui_print "------------------------------";
  ui_print " SELinux mode";
  kurumi_print_controls;
  KSELINUX_IDX=0;
  kurumi_render_selinux;
  while true; do
    if $FUNCTION; then
      break;
    fi;
    KSELINUX_IDX=$((KSELINUX_IDX + 1));
    [ "$KSELINUX_IDX" -gt 1 ] && KSELINUX_IDX=0;
    ui_print " ";
    kurumi_render_selinux;
  done;
  ui_print "------------------------------";
  if [ "$KSELINUX_IDX" -eq 0 ]; then
    KSELINUX=enforcing;
    SELINUX_LABEL="Enforcing";
  else
    KSELINUX=permissive;
    SELINUX_LABEL="Permissive";
  fi;
  ui_print " " "   Selected: $SELINUX_LABEL";

  if [ "$KPROFILE" != "skip" ]; then
    KDAEMON_VARIANT="kurumi_$KPROFILE";
    [ "$KFAN" = "enabled" ] && KDAEMON_VARIANT="${KDAEMON_VARIANT}_fan";
  fi;

  case "$KGPU" in
    skip) GPU_LABEL="Unchanged (RedMagic OS)";;
    stock) GPU_LABEL="Stock GPU DTB";;
    kurumi_low) GPU_LABEL="Kurumi - Low voltage";;
    kurumi_high) GPU_LABEL="Kurumi - High voltage";;
    *) GPU_LABEL="Kurumi - Balanced";;
  esac;
  case "$KPROFILE" in
    eco) DAEMON_LABEL="Economy ($KDAEMON_VARIANT)";;
    balance) DAEMON_LABEL="Balance ($KDAEMON_VARIANT)";;
    full) DAEMON_LABEL="Full ($KDAEMON_VARIANT)";;
    *)
      if [ "$KDAEMON_REASON" = "no_magisk" ]; then
        DAEMON_LABEL="Not available - Magisk not found";
      else
        DAEMON_LABEL="Not installed";
      fi
      ;;
  esac;
  if [ "$KPROFILE" = "skip" ]; then
    FAN_LABEL="Not installed";
  elif [ "$KFAN" = "enabled" ]; then
    FAN_LABEL="Automatic Kurumi control";
  else
    FAN_LABEL="Stock/manual control";
  fi;

  # ---- final review; the same cursor chooses install or full re-selection ----
  ui_print " ";
  ui_print "==============================";
  ui_print " Installation summary";
  ui_print "==============================";
  ui_print "   Firmware : $ROM_LABEL";
  ui_print "   Kernel   : $KERNEL_LABEL";
  ui_print "   Daemon   : $DAEMON_LABEL";
  ui_print "   Cooler   : $FAN_LABEL";
  ui_print "   GPU DTB  : $GPU_LABEL";
  ui_print "   SELinux  : $SELINUX_LABEL";
  ui_print " ";
  kurumi_print_controls;
  KCONFIRM_IDX=0;
  kurumi_render_confirmation;
  while true; do
    if $FUNCTION; then
      break;
    fi;
    KCONFIRM_IDX=$((KCONFIRM_IDX + 1));
    [ "$KCONFIRM_IDX" -gt 1 ] && KCONFIRM_IDX=0;
    ui_print " ";
    kurumi_render_confirmation;
  done;
  ui_print "------------------------------";
  if [ "$KCONFIRM_IDX" -eq 0 ]; then
    ui_print " " "   Settings confirmed. Installing...";
    break;
  fi;

  ui_print " ";
  ui_print "==============================";
  ui_print " Repeating configuration";
  ui_print "==============================";
done;

rm -f "$home/kurumi_events";
ui_print " ";
