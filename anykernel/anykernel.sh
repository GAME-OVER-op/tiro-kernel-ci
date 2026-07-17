### Kurumi Kernel Ramdisk Mod Script
## Kurumi Kernel

### Kurumi Kernel setup
# begin properties
properties() { '
kernel.string=tiro kernel (GAME-OVER-op) by kurumi
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=tiro
device.name2=NX769J
device.name3=NX769S
device.name4=RedMagic 9 Pro
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

## 1) Flash the Kurumi kernel
#  GKI (init_boot present): the kernel lives in boot and the ramdisk lives in
#  init_boot, so flash the kernel to boot without repacking a ramdisk.
if [ -L "/dev/block/bootdevice/by-name/init_boot_a" -o -L "/dev/block/by-name/init_boot_a" ]; then
    split_boot; # GKI: kernel lives in boot
    flash_boot;
    kurumi_rd_block=init_boot;
else
    dump_boot;
    write_boot;
    kurumi_rd_block=boot;
fi;

## 2) Bake the Kurumi battery tweak into the ramdisk via overlay.d
#  overlay.d/*.rc + overlay.d/sbin/* are imported and run by Magisk on boot,
#  so the tuning ships INSIDE the kernel flash -- no separate Magisk module.
#  Patches init_boot on GKI, or boot on legacy layouts.
if [ -d "$home/ramdisk/overlay.d" ]; then
    ui_print " " "Kurumi: installing in-kernel battery tweak (overlay.d) into $kurumi_rd_block...";
    cp -rf "$home/ramdisk/overlay.d" "$home/kurumi_overlay";
    reset_ak;
    block=$kurumi_rd_block;
    dump_boot;
    mkdir -p "$ramdisk/overlay.d/sbin";
    cp -rf "$home/kurumi_overlay/." "$ramdisk/overlay.d/";
    set_perm_recursive 0 0 755 644 "$ramdisk/overlay.d";
    set_perm_recursive 0 0 755 755 "$ramdisk/overlay.d/sbin";
    write_boot;
fi;
## end install
