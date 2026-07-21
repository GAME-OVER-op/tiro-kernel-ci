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

## Stash overlay.d before any reset wipes the shipped ramdisk dir
if [ -d "$home/ramdisk/overlay.d" ]; then
  cp -rf "$home/ramdisk/overlay.d" "$home/kurumi_overlay";
fi;

## Install the selected CPU-profile binary as the daemon (kurumi_battery).
## CI ships all three in kurumi_bin/; init.kurumi.rc launches kurumi_battery.
mkdir -p "$home/kurumi_overlay/sbin";
if [ -f "$home/kurumi_bin/kurumi_$KPROFILE" ]; then
  cp -f "$home/kurumi_bin/kurumi_$KPROFILE" "$home/kurumi_overlay/sbin/kurumi_battery";
  ui_print " " "Kurumi: staged '$KPROFILE' battery profile";
else
  ui_print " " "WARNING: kurumi_$KPROFILE not found - battery daemon will NOT be installed";
fi;

## GPU: on 'yes', stage the custom dtb as $home/dtb so flash_boot injects it into
## the boot image during repack. On 'no' no dtb file is staged -> the device's
## original (stock) dtb is preserved untouched.
if [ "$KGPU" = "1" ] && [ -f "$home/kurumi_gpu.dtb" ]; then
  cp -f "$home/kurumi_gpu.dtb" "$home/dtb";
  ui_print " " "Kurumi: custom GPU frequency table will be flashed into boot";
fi;

if [ -e "/dev/block/bootdevice/by-name/init_boot$slot" ] || [ -e "/dev/block/by-name/init_boot$slot" ] || [ -L "/dev/block/bootdevice/by-name/init_boot_a" ] || [ -L "/dev/block/by-name/init_boot_a" ]; then
  ## ---- GKI: kernel (+ optional GPU dtb) in boot, ramdisk (Magisk + overlay.d) in init_boot ----
  split_boot;
  apply_selinux;
  flash_boot;
  ## the GPU dtb belongs ONLY in boot - drop it so the init_boot pass never sees it
  rm -f "$home/dtb";
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
## end install
