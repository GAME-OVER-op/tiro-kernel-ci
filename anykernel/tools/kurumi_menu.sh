#
# Kurumi Kernel - interactive flash-time menu (getevent / keycheck driven)
# Sourced by anykernel.sh AFTER tools/ak3-core.sh so ui_print/$bin/abort exist.
# Exports: KKSU (0|1), KPROFILE (eco|balance|full|skip), KSELINUX (permissive|enforcing), KGPU (0|1)
#
# Key model ($FUNCTION returns 0 for Vol Up, 1 for Vol Down):
#   binary menus  -> Vol Up = Yes/first  | Vol Down = No/second
#   profile menu  -> Vol Down = move the '>' cursor | Vol Up = select pointed item
#

ui_print " ";
ui_print "==============================";
ui_print " Kurumi Kernel installer";
ui_print "==============================";

# ---- key detection: getevent if the recovery exposes it, else keycheck binary ----
keytest() {
  ui_print " " "   Press a Vol key to begin...";
  (/system/bin/getevent -lc 1 2>&1 | /system/bin/grep VOLUME | /system/bin/grep " DOWN" > $home/kurumi_events) || return 1;
  return 0;
}

chooseport() {
  while true; do
    /system/bin/getevent -lc 1 2>&1 | /system/bin/grep VOLUME | /system/bin/grep " DOWN" > $home/kurumi_events;
    if `cat $home/kurumi_events 2>/dev/null | /system/bin/grep VOLUME >/dev/null`; then
      break;
    fi;
  done;
  if `cat $home/kurumi_events 2>/dev/null | /system/bin/grep VOLUMEUP >/dev/null`; then
    return 0;
  else
    return 1;
  fi;
}

chooseportold() {
  # First call clears any previous input; the second reads the real keypress.
  $bin/keycheck;
  $bin/keycheck;
  SEL=$?;
  if [ "$1" == "UP" ]; then
    UP=$SEL;
  elif [ "$1" == "DOWN" ]; then
    DOWN=$SEL;
  elif [ $SEL -eq $UP ]; then
    return 0;
  elif [ $SEL -eq $DOWN ]; then
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

# ---- 0) Root: KernelSU-Next + susfs (asked only if the KSU image is in the zip) ----
if [ -f "$home/files/image/kurumi_ksu" ]; then
  ui_print " ";
  ui_print "------------------------------";
  ui_print " Root: install KernelSU-Next?";
  ui_print "   (KSU-Next; susfs if built this release)";
  ui_print "   Vol+ = Yes  (install KSU kernel)";
  ui_print "   Vol- = No   (clean stock kernel)";
  ui_print "------------------------------";
  if $FUNCTION; then
    KKSU=1;
    ui_print " " "   -> KernelSU-Next + susfs selected";
  else
    KKSU=0;
    ui_print " " "   -> Stock kernel (no root) selected";
  fi;
else
  KKSU=0;
fi;

# ---- 1) Battery daemon profile (scrolling cursor menu; 'Skip' = do not install it) ----
# The daemon runs only under Magisk (its overlay.d rc is imported by magiskinit). On
# KSU/APatch/no-root it stays dormant and harmless, so we still offer the profiles to
# everyone and let non-Magisk users pick 'Skip' if they don't want it staged at all.
ui_print " ";
ui_print "------------------------------";
ui_print " Battery daemon profile (active on Magisk)";
ui_print "   Vol Down = move cursor";
ui_print "   Vol Up   = select";
ui_print "------------------------------";
KP_IDX=0;
while true; do
  ui_print " ";
  if [ $KP_IDX -eq 0 ]; then ui_print " > Economy - max battery (big -60%, mid -30%, little -20%)"; else ui_print "   Economy - max battery (big -60%, mid -30%, little -20%)"; fi;
  if [ $KP_IDX -eq 1 ]; then ui_print " > Balance - mid -20%, big -30%, little untouched"; else ui_print "   Balance - mid -20%, big -30%, little untouched"; fi;
  if [ $KP_IDX -eq 2 ]; then ui_print " > Full    - no CPU limits (default)"; else ui_print "   Full    - no CPU limits (default)"; fi;
  if [ $KP_IDX -eq 3 ]; then ui_print " > Skip    - do not install the battery daemon"; else ui_print "   Skip    - do not install the battery daemon"; fi;
  if $FUNCTION; then
    break;
  else
    KP_IDX=$((KP_IDX + 1));
    [ $KP_IDX -gt 3 ] && KP_IDX=0;
  fi;
done;
case $KP_IDX in
  0) KPROFILE=eco;;
  1) KPROFILE=balance;;
  2) KPROFILE=full;;
  3) KPROFILE=skip;;
esac;
ui_print " " "   -> profile: $KPROFILE";

# ---- 2) SELinux mode (binary) ----
ui_print " ";
ui_print "------------------------------";
ui_print " SELinux mode";
ui_print "   Vol+ = Permissive";
ui_print "   Vol- = Enforcing (stock)";
ui_print "------------------------------";
if $FUNCTION; then
  KSELINUX=permissive;
  ui_print " " "   -> SELinux: permissive";
else
  KSELINUX=enforcing;
  ui_print " " "   -> SELinux: enforcing";
fi;

# ---- 3) Custom GPU frequency table (binary) ----
ui_print " ";
ui_print "------------------------------";
ui_print " GPU frequency table (flashed to vendor_boot)";
ui_print "   Vol+ = Yes - install CUSTOM table (adds 80/120/180 + 916 MHz)";
ui_print "   Vol- = No  - restore STOCK dtb (revert to stock)";
ui_print "------------------------------";
if $FUNCTION; then
  KGPU=1;
  ui_print " " "   -> CUSTOM GPU table -> vendor_boot";
else
  KGPU=0;
  ui_print " " "   -> STOCK GPU dtb -> vendor_boot (revert)";
fi;

rm -f $home/kurumi_events;
ui_print " ";
