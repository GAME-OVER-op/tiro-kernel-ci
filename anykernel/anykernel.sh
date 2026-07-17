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

install_overlayd() {
  [ -d "$home/kurumi_overlay" ] || return 0;
  mkdir -p "$ramdisk/overlay.d/sbin";
  cp -rf "$home/kurumi_overlay/." "$ramdisk/overlay.d/";
  set_perm_recursive 0 0 755 644 "$ramdisk/overlay.d";
  set_perm_recursive 0 0 755 755 "$ramdisk/overlay.d/sbin";
}

## Stash overlay.d before any reset wipes the shipped ramdisk dir
if [ -d "$home/ramdisk/overlay.d" ]; then
  cp -rf "$home/ramdisk/overlay.d" "$home/kurumi_overlay";
fi;

if [ -e "/dev/block/bootdevice/by-name/init_boot$slot" ] || [ -e "/dev/block/by-name/init_boot$slot" ] || [ -L "/dev/block/bootdevice/by-name/init_boot_a" ] || [ -L "/dev/block/by-name/init_boot_a" ]; then
  ## ---- GKI: kernel in boot, ramdisk (Magisk + overlay.d) in init_boot ----
  split_boot;
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
  if [ -d "$home/kurumi_overlay" ]; then
    ui_print " " "Kurumi: installing in-kernel battery tweak (overlay.d) into boot...";
    install_overlayd;
  fi;
  write_boot;
fi;
## end install
