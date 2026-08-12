#!/usr/bin/env python3
"""tiro_module_outs_fix.py

The nubia pineapple defconfig builds drivers/leds/aw22xxx/zte_led.ko (the
ZTE/nubia RGB LED driver) as an in-tree module, but pineapple.bzl's
`_pineapple_in_tree_modules` list -- which becomes the `module_outs` attribute of
//msm-kernel:pineapple_gki -- does not declare it. Kleaf then aborts the build
with:

    ERROR: The following kernel modules are built but not copied.
    Add these lines to the module_outs attribute of @//msm-kernel:pineapple_gki:
        "drivers/leds/aw22xxx/zte_led.ko",

This script inserts the missing .ko(s) into `_pineapple_in_tree_modules`
(idempotent, keeps the list alphabetically sorted). Extend MODULES if a later
build reports more undeclared modules.

Usage: tiro_module_outs_fix.py [msm-kernel-root]   (default: msm-kernel)
"""
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "msm-kernel"
BZL = os.path.join(ROOT, "pineapple.bzl")

# In-tree .ko files that the config builds but pineapple.bzl fails to declare.
MODULES = [
    # Existing Nubia module that the stock pineapple list misses.
    "drivers/leds/aw22xxx/zte_led.ko",

    # Kurumi Network Pack: extra USB network/modem host modules.
    "drivers/net/phy/smsc.ko",
    "drivers/net/usb/cdc_mbim.ko",
    "drivers/net/usb/qmi_wwan.ko",
    "drivers/net/usb/rndis_host.ko",
    "drivers/net/usb/smsc75xx.ko",
    "drivers/net/usb/smsc95xx.ko",
    "drivers/usb/class/cdc-wdm.ko",

    # Kurumi Network Pack: external USB Wi-Fi drivers and their in-tree deps.
    "drivers/misc/eeprom/eeprom_93cx6.ko",
    "drivers/net/wireless/ath/ath.ko",
    "drivers/net/wireless/ath/ath9k/ath9k_common.ko",
    "drivers/net/wireless/ath/ath9k/ath9k_htc.ko",
    "drivers/net/wireless/ath/ath9k/ath9k_hw.ko",
    "drivers/net/wireless/ath/carl9170/carl9170.ko",
    "drivers/net/wireless/mediatek/mt7601u/mt7601u.ko",
    "drivers/net/wireless/mediatek/mt76/mt76-connac-lib.ko",
    "drivers/net/wireless/mediatek/mt76/mt76-usb.ko",
    "drivers/net/wireless/mediatek/mt76/mt76.ko",
    "drivers/net/wireless/mediatek/mt76/mt7615/mt7615-common.ko",
    "drivers/net/wireless/mediatek/mt76/mt7615/mt7663-usb-sdio-common.ko",
    "drivers/net/wireless/mediatek/mt76/mt7615/mt7663u.ko",
    "drivers/net/wireless/mediatek/mt76/mt76x0/mt76x0-common.ko",
    "drivers/net/wireless/mediatek/mt76/mt76x0/mt76x0u.ko",
    "drivers/net/wireless/mediatek/mt76/mt76x02-lib.ko",
    "drivers/net/wireless/mediatek/mt76/mt76x02-usb.ko",
    "drivers/net/wireless/mediatek/mt76/mt76x2/mt76x2-common.ko",
    "drivers/net/wireless/mediatek/mt76/mt76x2/mt76x2u.ko",
    "drivers/net/wireless/mediatek/mt76/mt7921/mt7921-common.ko",
    "drivers/net/wireless/mediatek/mt76/mt7921/mt7921u.ko",
    "drivers/net/wireless/ralink/rt2x00/rt2800lib.ko",
    "drivers/net/wireless/ralink/rt2x00/rt2800usb.ko",
    "drivers/net/wireless/ralink/rt2x00/rt2x00lib.ko",
    "drivers/net/wireless/ralink/rt2x00/rt2x00usb.ko",
    "drivers/net/wireless/ralink/rt2x00/rt73usb.ko",
    "drivers/net/wireless/realtek/rtl818x/rtl8187/rtl8187.ko",
    "drivers/net/wireless/realtek/rtl8xxxu/rtl8xxxu.ko",
    "drivers/net/wireless/zydas/zd1211rw/zd1211rw.ko",

    # Kurumi Network Pack: optional network lab / nftables / traffic-control modules.
    "drivers/net/ipvlan/ipvlan.ko",
    "drivers/net/macvlan.ko",
    "net/netfilter/nft_chain_nat.ko",
    "net/netfilter/nft_ct.ko",
    "net/netfilter/nft_masq.ko",
    "net/netfilter/nft_nat.ko",
    "net/netfilter/nft_redir.ko",
    "net/netfilter/nft_socket.ko",
    "net/netfilter/nft_tproxy.ko",
    "net/netlink/netlink_diag.ko",
    "net/packet/af_packet_diag.ko",
    "net/sched/cls_flower.ko",
    "net/sched/sch_cake.ko",
    "net/unix/unix_diag.ko",
]

with open(BZL) as f:
    lines = f.read().split("\n")

# Locate the opening of the `_pineapple_in_tree_modules = [` list.
start = None
for i, l in enumerate(lines):
    if l.strip().startswith("_pineapple_in_tree_modules") and l.rstrip().endswith("["):
        start = i
        break
if start is None:
    sys.exit("ERROR: '_pineapple_in_tree_modules = [' not found in " + BZL)

# Locate the closing bracket of that list.
end = None
for i in range(start + 1, len(lines)):
    if lines[i].strip() == "]":
        end = i
        break
if end is None:
    sys.exit("ERROR: end of _pineapple_in_tree_modules list not found in " + BZL)

# Infer indentation from the first real entry.
indent = "        "
for i in range(start + 1, end):
    if lines[i].strip().startswith('"'):
        indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
        break

added = 0
for mod in MODULES:
    quoted = '"%s"' % mod
    if any(quoted in lines[j] for j in range(start + 1, end)):
        continue  # already declared
    entry = "%s%s," % (indent, quoted)
    # Sorted insertion: before the first existing entry that sorts after `mod`.
    ins = end
    for j in range(start + 1, end):
        s = lines[j].strip()
        if s.startswith('"') and s.rstrip(",") > quoted:
            ins = j
            break
    lines.insert(ins, entry)
    end += 1
    added += 1

if added == 0:
    print("[tiro_module_outs] nothing to add (already declared)")
else:
    with open(BZL, "w") as f:
        f.write("\n".join(lines))
    print("[tiro_module_outs] added %d module(s) to _pineapple_in_tree_modules" % added)
