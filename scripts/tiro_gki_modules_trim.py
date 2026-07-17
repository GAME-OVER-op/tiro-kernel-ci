#!/usr/bin/env python3
"""
tiro_gki_modules_trim.py

Remove kernel modules that we intentionally disabled in gki_defconfig from the
nubia msm-kernel module manifests, so Kleaf stops expecting them as build
outputs of //msm-kernel:pineapple_gki.

Why: cdc-acm / usbserial / ftdi_sio / rfcomm reference the 3-arg
__tty_port_tty_hangup, which the OnePlus GKI base vmlinux does not export.
They are disabled in gki_defconfig; this keeps the manifests consistent.

Edits (idempotent):
  * modules.bzl                            -> drop from _COMMON_GKI_MODULES_LIST
                                              (feeds module_implicit_outs)
  * android/gki_aarch64_protected_modules  -> drop matching plain lines
                                              (feeds protected_modules_list)

Usage: tiro_gki_modules_trim.py [MSM_KERNEL_ROOT]
"""
import os
import sys

MODS = [
    "drivers/usb/class/cdc-acm.ko",
    "drivers/usb/serial/ftdi_sio.ko",
    "drivers/usb/serial/usbserial.ko",
    "net/bluetooth/rfcomm/rfcomm.ko",
]


def trim_bzl(path):
    with open(path) as f:
        lines = f.readlines()
    wanted = set(MODS)
    out, removed = [], 0
    for ln in lines:
        s = ln.strip()
        val = s[:-1].strip() if s.endswith(",") else s
        if len(val) >= 2 and val[0] == '"' and val[-1] == '"' and val[1:-1] in wanted:
            removed += 1
            continue
        out.append(ln)
    if removed:
        with open(path, "w") as f:
            f.writelines(out)
    return removed


def trim_plain(path):
    if not os.path.exists(path):
        return 0
    with open(path) as f:
        lines = f.readlines()
    wanted = set(MODS)
    out, removed = [], 0
    for ln in lines:
        if ln.strip() in wanted:
            removed += 1
            continue
        out.append(ln)
    if removed:
        with open(path, "w") as f:
            f.writelines(out)
    return removed


def still_present(path):
    if not os.path.exists(path):
        return []
    txt = open(path).read()
    return [m for m in MODS if m in txt]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "msm-kernel"
    bzl = os.path.join(root, "modules.bzl")
    prot = os.path.join(root, "android", "gki_aarch64_protected_modules")
    if not os.path.exists(bzl):
        sys.exit("[tiro_gki_modules_trim] ERROR: %s not found" % bzl)
    r1 = trim_bzl(bzl)
    r2 = trim_plain(prot)
    print("[tiro_gki_modules_trim] modules.bzl removed=%d, protected_modules removed=%d" % (r1, r2))
    leftover = still_present(bzl) + still_present(prot)
    if leftover:
        sys.exit("[tiro_gki_modules_trim] ERROR: still present: %s" % ", ".join(sorted(set(leftover))))
    print("[tiro_gki_modules_trim] OK")


if __name__ == "__main__":
    main()
