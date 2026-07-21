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
## Sets KPROFILE (eco|balance|full), KSELINUX (permissive|enforcing), KGPU (0|1)
. $home/tools/kurumi_menu.sh

install_overlayd() {
  [ -d "$home/kurumi_overlay" ] || return 0;
  mkdir -p "$ramdisk/overlay.d/sbin";
  cp -rf "$home/kurumi_overlay/." "$ramdisk/overlay.d/";
  set_perm_recursive 0 0 755 644 "$ramdisk/overlay.d";
  set_perm_recursive 0 0 755 755 "$ramdisk/overlay.d/sbin";
}

## SELinux: patch the kernel cmdline to the chosen mode
apply_selinux() {
  if [ "$KSELINUX" = "permissive" ]; then
    patch_cmdline androidboot.selinux "androidboot.selinux=permissive";
  else
    patch_cmdline androidboot.selinux "androidboot.selinux=enforcing";
  fi;
}

## Battery daemon (overlay.d). If the user picked 'Skip' in the profile menu we install
## NOTHING (no kurumi_overlay -> install_overlayd is a no-op and the init_boot overlay pass
## is skipped). Otherwise the overlay is baked into init_boot UNCONDITIONALLY: it only runs
## under Magisk (magiskinit imports overlay.d); on KSU/APatch/no-root it stays dormant and
## harmless (stock init ignores /overlay.d), so it cannot break boot.
if [ "$KPROFILE" = "skip" ]; then
  rm -rf "$home/kurumi_overlay";
  ui_print " " "Kurumi: battery daemon skipped (no overlay installed)";
else
  ## Stash overlay.d before any reset wipes the shipped ramdisk dir
  if [ -d "$home/ramdisk/overlay.d" ]; then
    cp -rf "$home/ramdisk/overlay.d" "$home/kurumi_overlay";
  fi;
  ## Install the selected CPU-profile binary as the daemon (kurumi_battery).
  ## CI ships all three in files/kurumi_bin/; init.kurumi.rc launches kurumi_battery.
  mkdir -p "$home/kurumi_overlay/sbin";
  if [ -f "$home/files/kurumi_bin/kurumi_$KPROFILE" ]; then
    cp -f "$home/files/kurumi_bin/kurumi_$KPROFILE" "$home/kurumi_overlay/sbin/kurumi_battery";
    ui_print " " "Kurumi: staged '$KPROFILE' battery profile (active only on Magisk)";
  else
    ui_print " " "WARNING: kurumi_$KPROFILE not found - battery daemon will NOT be installed";
    rm -rf "$home/kurumi_overlay";
  fi;
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

## ---- Kernel image selection: stock vs KernelSU-Next + susfs ----
## CI ships BOTH variants under files/image/ (names AnyKernel will NOT auto-detect: kurumi_stock
## / kurumi_ksu) plus the real image basename in files/image/kurumi_imgname. Copy the chosen
## variant to $home/<name> (root) so AnyKernel's split_boot/flash_boot picks it up. If KSU was
## requested but its image is missing (e.g. the KSU build was skipped this run), fall back to
## stock with a warning.
IMGNAME="Image.gz";
[ -f "$home/files/image/kurumi_imgname" ] && IMGNAME="$(cat "$home/files/image/kurumi_imgname")";
KSEL="";
if [ "$KKSU" = "1" ] && [ -f "$home/files/image/kurumi_ksu" ]; then
  KSEL="$home/files/image/kurumi_ksu";
  _susfs=no; [ -f "$home/files/image/kurumi_ksu_susfs" ] && _susfs="$(cat "$home/files/image/kurumi_ksu_susfs")";
  ui_print " " "Kurumi: flashing KernelSU-Next kernel (susfs: $_susfs)";
elif [ -f "$home/files/image/kurumi_stock" ]; then
  KSEL="$home/files/image/kurumi_stock";
  ui_print " " "Kurumi: flashing stock (no-root) kernel";
fi;
if [ -n "$KSEL" ]; then
  cp -f "$KSEL" "$home/$IMGNAME";
fi;
rm -f "$home/files/image/kurumi_stock" "$home/files/image/kurumi_ksu" "$home/files/image/kurumi_ksu_susfs";

if [ -e "/dev/block/bootdevice/by-name/init_boot$slot" ] || [ -e "/dev/block/by-name/init_boot$slot" ] || [ -L "/dev/block/bootdevice/by-name/init_boot_a" ] || [ -L "/dev/block/by-name/init_boot_a" ]; then
  ## ---- GKI: kernel (+ optional GPU dtb) in boot, ramdisk (Magisk + overlay.d) in init_boot ----
  split_boot;
  apply_selinux;
  flash_boot;
  if [ -d "$home/kurumi_overlay" ]; then
    ui_print " " "Kurumi: installing in-kernel battery tweak (overlay.d) into init_boot...";
    rm -f "$home"/Image "$home"/Image.gz "$home"/Image-dtb "$home"/Image.gz-dtb "$home"/zImage "$home"/zImage-dtb;
    reset_ak;
    block=init_boot;
    setup_ak;
    dump_boot;
    install_overlayd;
    write_boot;
  fi;
else
  ## ---- legacy: kernel + ramdisk both in boot -> single pass ----
  dump_boot;
  apply_selinux;
  if [ -d "$home/kurumi_overlay" ]; then
    ui_print " " "Kurumi: installing in-kernel battery tweak (overlay.d) into boot...";
    install_overlayd;
  fi;
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
