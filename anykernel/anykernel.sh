### Kurumi Kernel Ramdisk Mod Script
## Kurumi Kernel

### Kurumi Kernel setup
# begin properties
properties() { '
kernel.string=tiro kernel (GAME-OVER-op) by kurumi
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=tiro
device.name2=NX769J
device.name3=NX769S
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
'; } # end properties

## boot shell variables
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=0
no_magisk_check=1

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

## ---- Kurumi interactive installer (keycheck/getevent driven menus) ----
## Sets KROOT (stock|ksu|susfs), KPROFILE (eco|balance|full), KSELINUX (permissive|enforcing), KGPU (0|1)
. $home/tools/kurumi_menu.sh

KURUMI_MODULE_DIR=/data/adb/modules/kurumi_kernel
KURUMI_MAGISK=0
KURUMI_OVERLAY_CHANGED=0

kurumi_remove_data_module() {
  if [ -d /data/adb/modules/kurumi_kernel ]; then
    ui_print " " "Kurumi: removing old KSU module /data/adb/modules/kurumi_kernel";
    rm -rf /data/adb/modules/kurumi_kernel 2>/dev/null || ui_print " " "WARNING: could not remove old kurumi_kernel module";
  fi;
}

kurumi_data_modules_ready() {
  [ -d /data/adb ] || return 1;
  mkdir -p /data/adb/modules 2>/dev/null || return 1;
  [ -d /data/adb/modules ] || return 1;
  [ -w /data/adb/modules ] || return 1;
  return 0;
}

kurumi_install_data_module() {
  local srcbin;
  [ "$KPROFILE" = "skip" ] && { kurumi_remove_data_module; return 0; };
  srcbin="$home/files/kurumi_bin/kurumi_$KPROFILE";
  [ -f "$srcbin" ] || { ui_print " " "WARNING: kurumi_$KPROFILE not found - KSU module skipped"; return 1; };
  [ -f "$home/files/kurumi_module/module.prop" ] || { ui_print " " "WARNING: kurumi module.prop missing - KSU module skipped"; return 1; };
  [ -f "$home/files/kurumi_module/service.sh" ] || { ui_print " " "WARNING: kurumi service.sh missing - KSU module skipped"; return 1; };
  if ! kurumi_data_modules_ready; then
    ui_print " " "WARNING: /data/adb/modules is not writable - Kurumi daemon module skipped";
    return 1;
  fi;
  ui_print " " "Kurumi: installing daemon as KSU module ($KPROFILE)";
  rm -rf "$KURUMI_MODULE_DIR" 2>/dev/null;
  mkdir -p "$KURUMI_MODULE_DIR" || { ui_print " " "WARNING: cannot create $KURUMI_MODULE_DIR"; return 1; };
  cp -f "$home/files/kurumi_module/module.prop" "$KURUMI_MODULE_DIR/module.prop" || return 1;
  cp -f "$home/files/kurumi_module/service.sh" "$KURUMI_MODULE_DIR/service.sh" || return 1;
  cp -f "$srcbin" "$KURUMI_MODULE_DIR/kurumi" || return 1;
  chown -R 0:0 "$KURUMI_MODULE_DIR" 2>/dev/null;
  chmod 0755 "$KURUMI_MODULE_DIR" 2>/dev/null;
  chmod 0644 "$KURUMI_MODULE_DIR/module.prop" 2>/dev/null;
  chmod 0755 "$KURUMI_MODULE_DIR/service.sh" "$KURUMI_MODULE_DIR/kurumi" 2>/dev/null;
  chcon -R u:object_r:adb_data_file:s0 "$KURUMI_MODULE_DIR" 2>/dev/null || /system/bin/chcon -R u:object_r:adb_data_file:s0 "$KURUMI_MODULE_DIR" 2>/dev/null || true;
  ui_print " " "Kurumi: KSU module installed to $KURUMI_MODULE_DIR";
}

kurumi_stage_overlay_profile() {
  rm -rf "$home/kurumi_overlay";
  [ "$KPROFILE" = "skip" ] && return 1;
  [ -d "$home/kurumi_overlay_template" ] || { ui_print " " "WARNING: overlay.d template missing - Magisk daemon skipped"; return 1; };
  [ -f "$home/files/kurumi_bin/kurumi_$KPROFILE" ] || { ui_print " " "WARNING: kurumi_$KPROFILE not found - Magisk daemon skipped"; return 1; };
  cp -rf "$home/kurumi_overlay_template" "$home/kurumi_overlay";
  mkdir -p "$home/kurumi_overlay/sbin";
  cp -f "$home/files/kurumi_bin/kurumi_$KPROFILE" "$home/kurumi_overlay/sbin/kurumi_battery";
  ui_print " " "Kurumi: staged '$KPROFILE' daemon profile for Magisk overlay.d";
  return 0;
}

install_overlayd() {
  [ -d "$home/kurumi_overlay" ] || return 0;
  mkdir -p "$ramdisk/overlay.d/sbin";
  cp -rf "$home/kurumi_overlay/." "$ramdisk/overlay.d/";
  set_perm_recursive 0 0 755 644 "$ramdisk/overlay.d";
  set_perm_recursive 0 0 755 755 "$ramdisk/overlay.d/sbin";
}

kurumi_remove_overlayd() {
  KURUMI_OVERLAY_CHANGED=0;
  if [ -f "$ramdisk/overlay.d/init.kurumi.rc" ]; then
    rm -f "$ramdisk/overlay.d/init.kurumi.rc";
    KURUMI_OVERLAY_CHANGED=1;
  fi;
  if [ -f "$ramdisk/overlay.d/sbin/kurumi_battery" ]; then
    rm -f "$ramdisk/overlay.d/sbin/kurumi_battery";
    KURUMI_OVERLAY_CHANGED=1;
  fi;
  rmdir "$ramdisk/overlay.d/sbin" "$ramdisk/overlay.d" 2>/dev/null || true;
}

kurumi_detect_magisk_ramdisk() {
  local rc;
  KURUMI_MAGISK=0;
  if [ -f "$split_img/ramdisk.cpio" ]; then
    "$bin"/magiskboot cpio "$split_img/ramdisk.cpio" test >/dev/null 2>&1;
    rc=$?;
    [ $((rc & 3)) -eq 1 ] && KURUMI_MAGISK=1;
  fi;
  if [ -f "$ramdisk/.backup/.magisk" ] || [ -f "$ramdisk/.magisk" ]; then
    KURUMI_MAGISK=1;
  fi;
  if [ "$KURUMI_MAGISK" = "1" ]; then
    ui_print " " "Kurumi: Magisk ramdisk/runtime detected";
  else
    ui_print " " "Kurumi: Magisk not detected";
  fi;
}

kurumi_finalize_daemon_for_current_ramdisk() {
  kurumi_detect_magisk_ramdisk;

  if [ "$KURUMI_MAGISK" = "1" ]; then
    # Magisk path has priority. Remove the KSU module to avoid a double daemon.
    kurumi_remove_data_module;
    kurumi_remove_overlayd;
    if [ "$KPROFILE" = "skip" ]; then
      ui_print " " "Kurumi: daemon skipped - Magisk overlay.d removed if present";
      return 0;
    fi;
    if kurumi_stage_overlay_profile; then
      install_overlayd;
      KURUMI_OVERLAY_CHANGED=1;
      ui_print " " "Kurumi: daemon will run through Magisk overlay.d";
    else
      ui_print " " "WARNING: Magisk detected but daemon overlay could not be staged";
    fi;
    return 0;
  fi;

  # No Magisk: keep the ramdisk clean. KSU/SuSFS can run the daemon from /data/adb/modules.
  kurumi_remove_overlayd;
  case "$KROOT" in
    ksu|susfs)
      if [ "$KPROFILE" = "skip" ]; then
        kurumi_remove_data_module;
        ui_print " " "Kurumi: daemon skipped - KSU module removed if present";
      else
        kurumi_install_data_module || true;
      fi;
      ;;
    *)
      kurumi_remove_data_module;
      ui_print " " "Kurumi: stock kernel without Magisk - daemon skipped";
      ;;
  esac;
}

## SELinux: patch the kernel cmdline to the chosen mode
apply_selinux() {
  if [ "$KSELINUX" = "permissive" ]; then
    patch_cmdline androidboot.selinux "androidboot.selinux=permissive";
  else
    patch_cmdline androidboot.selinux "androidboot.selinux=enforcing";
  fi;
}

## ---- Kurumi daemon runtime routing ----
## Keep the overlay.d template out of the normal ramdisk auto-merge path.
## Later, after the target ramdisk is dumped, we choose exactly ONE runtime:
##   Magisk detected              -> overlay.d in boot/init_boot (existing logic)
##   no Magisk + KSU/KSU+SuSFS    -> /data/adb/modules/kurumi_kernel
##   stock without Magisk or Skip -> no daemon, old Kurumi module/overlay removed
if [ -d "$home/ramdisk/overlay.d" ]; then
  rm -rf "$home/kurumi_overlay_template";
  cp -rf "$home/ramdisk/overlay.d" "$home/kurumi_overlay_template";
  rm -rf "$home/ramdisk/overlay.d";
  rmdir "$home/ramdisk" 2>/dev/null || true;
fi;

# If the user selects stock or explicit Skip, clear stale KSU module early.
# This prevents a previous KSU/SuSFS install from resurrecting the daemon later.
if [ "$KROOT" = "stock" ] || [ "$KPROFILE" = "skip" ]; then
  kurumi_remove_data_module;
fi;

## GPU frequency table -> staged for the vendor_boot pass below (NOT boot). 'Yes' stages the
## CUSTOM table; 'No' stages the STOCK dtb so the user can always revert. Either way the dtb is
## written to vendor_boot further down; boot's own dtb is never touched. Staged under a private
## name (kurumi_vendor_dtb) so AK3's split_boot/flash_boot never auto-injects it into boot.
if [ "$KGPU" = "1" ] && [ -f "$home/files/dtb/kurumi_gpu.dtb" ]; then
  cp -f "$home/files/dtb/kurumi_gpu.dtb" "$home/kurumi_vendor_dtb";
  ui_print " " "Kurumi: CUSTOM GPU frequency table -> vendor_boot";
elif [ -f "$home/files/dtb/stock_gpu.dtb" ]; then
  cp -f "$home/files/dtb/stock_gpu.dtb" "$home/kurumi_vendor_dtb";
  ui_print " " "Kurumi: STOCK GPU dtb -> vendor_boot (revert to stock)";
fi;

## ---- Kernel image selection: stock / KernelSU-Next / KernelSU-Next + susfs ----
## CI ships up to THREE variants under files/image/ (names AnyKernel will NOT auto-detect):
##   kurumi_stock, kurumi_ksu, kurumi_ksu_susfs
## plus the real image basename in files/image/kurumi_imgname. Copy the chosen variant to
## $home/<name> (root) so AnyKernel's split_boot/flash_boot picks it up. If a requested
## variant is missing, fall back safely instead of flashing nothing.
IMGNAME="Image.gz";
[ -f "$home/files/image/kurumi_imgname" ] && IMGNAME="$(cat "$home/files/image/kurumi_imgname")";
KSEL="";
case "$KROOT" in
  susfs)
    if [ -f "$home/files/image/kurumi_ksu_susfs" ]; then
      KSEL="$home/files/image/kurumi_ksu_susfs";
      ui_print " " "Kurumi: flashing KernelSU-Next + susfs kernel";
    elif [ -f "$home/files/image/kurumi_ksu" ]; then
      KSEL="$home/files/image/kurumi_ksu";
      ui_print " " "WARNING: KSU+susfs image missing - flashing KernelSU-Next only";
    elif [ -f "$home/files/image/kurumi_stock" ]; then
      KSEL="$home/files/image/kurumi_stock";
      ui_print " " "WARNING: KSU+susfs image missing - flashing stock kernel";
    fi;
    ;;
  ksu)
    if [ -f "$home/files/image/kurumi_ksu" ]; then
      KSEL="$home/files/image/kurumi_ksu";
      ui_print " " "Kurumi: flashing KernelSU-Next kernel";
    elif [ -f "$home/files/image/kurumi_stock" ]; then
      KSEL="$home/files/image/kurumi_stock";
      ui_print " " "WARNING: KernelSU image missing - flashing stock kernel";
    fi;
    ;;
  *)
    if [ -f "$home/files/image/kurumi_stock" ]; then
      KSEL="$home/files/image/kurumi_stock";
      ui_print " " "Kurumi: flashing stock (no-root) kernel";
    fi;
    ;;
esac;
[ -n "$KSEL" ] || abort "Kurumi: no selectable kernel image found in zip";
cp -f "$KSEL" "$home/$IMGNAME";
rm -f "$home/files/image/kurumi_stock" "$home/files/image/kurumi_ksu" "$home/files/image/kurumi_ksu_susfs";

if [ -e "/dev/block/bootdevice/by-name/init_boot$slot" ] || [ -e "/dev/block/by-name/init_boot$slot" ] || [ -L "/dev/block/bootdevice/by-name/init_boot_a" ] || [ -L "/dev/block/by-name/init_boot_a" ]; then
  ## ---- GKI: kernel (+ optional GPU dtb) in boot, ramdisk (Magisk + overlay.d) in init_boot ----
  split_boot;
  apply_selinux;
  flash_boot;

  ## Inspect init_boot for Magisk, then either install overlay.d, install a KSU
  ## module, or remove stale Kurumi daemon files. Do not keep overlay.d and
  ## /data/adb/modules/kurumi_kernel active at the same time.
  ui_print " " "Kurumi: checking init_boot for Magisk daemon runtime...";
  rm -f "$home"/Image "$home"/Image.gz "$home"/Image-dtb "$home"/Image.gz-dtb "$home"/zImage "$home"/zImage-dtb;
  reset_ak;
  block=init_boot;
  setup_ak;
  dump_boot;
  kurumi_finalize_daemon_for_current_ramdisk;
  if [ "$KURUMI_MAGISK" = "1" ] || [ "$KURUMI_OVERLAY_CHANGED" = "1" ]; then
    write_boot;
  else
    ui_print " " "Kurumi: init_boot left unchanged (no Magisk overlay needed)";
  fi;
else
  ## ---- legacy: kernel + ramdisk both in boot -> single pass ----
  dump_boot;
  apply_selinux;
  kurumi_finalize_daemon_for_current_ramdisk;
  write_boot;
fi;
## ---- GPU dtb -> vendor_boot (independent of kernel; runs for BOTH 'custom' and 'stock') ----
## The GPU frequency table lives in the vendor_boot dtb on this device, NOT in boot. AK3's auto
## multi-partition router would misroute a $home/dtb to vendor_kernel_boot on init_boot devices,
## and a full vendor_boot v4 ramdisk repack is unreliable - so swap ONLY the dtb surgically with
## magiskboot: dump vendor_boot, replace its dtb section, repack, write back. Guarded so it
## aborts (never writes) if vendor_boot has no dtb or the repack grew past the partition.
if [ -f "$home/kurumi_vendor_dtb" ]; then
  VBP="";
  for p in /dev/block/bootdevice/by-name/vendor_boot$slot /dev/block/by-name/vendor_boot$slot /dev/block/bootdevice/by-name/vendor_boot /dev/block/by-name/vendor_boot; do
    [ -e "$p" ] && { VBP="$p"; break; };
  done;
  if [ -z "$VBP" ]; then
    ui_print " " "Kurumi: vendor_boot not found - GPU dtb skipped (device layout differs)";
  else
    ui_print " " "Kurumi: writing GPU dtb into vendor_boot ($VBP)...";
    rm -rf "$home/vbwork"; mkdir -p "$home/vbwork"; cd "$home/vbwork";
    dd if="$VBP" of=vendor_boot.img bs=1048576 2>/dev/null || abort "Kurumi: failed to read vendor_boot";
    "$bin"/magiskboot unpack vendor_boot.img || abort "Kurumi: could not unpack vendor_boot";
    [ -f dtb ] || abort "Kurumi: vendor_boot has no dtb section - aborting (no write)";
    cp -f "$home/kurumi_vendor_dtb" dtb;
    "$bin"/magiskboot repack vendor_boot.img vendor_boot-new.img || abort "Kurumi: could not repack vendor_boot";
    if [ "$(wc -c < vendor_boot-new.img)" -gt "$(wc -c < vendor_boot.img)" ]; then
      abort "Kurumi: new vendor_boot larger than partition - aborting (no write)";
    fi;
    blockdev --setrw "$VBP" 2>/dev/null;
    cat vendor_boot-new.img /dev/zero > "$VBP" 2>/dev/null || dd if=vendor_boot-new.img of="$VBP";
    ui_print " " "Kurumi: vendor_boot dtb updated";
    cd "$home"; rm -rf "$home/vbwork";
  fi;
  rm -f "$home/kurumi_vendor_dtb";
fi;

## end install
