#!/usr/bin/env bash
set -euo pipefail

OUT_ROOT="${1:-out}"
DEST="${2:-${GITHUB_WORKSPACE:-$PWD}/net_modules}"
LIB="$DEST/lib/modules"
mkdir -p "$LIB"
rm -f "$LIB"/*.ko "$DEST/modules.load" "$DEST/README.txt" 2>/dev/null || true

# Load order: dependencies first, leaf USB Wi-Fi / USB Ethernet drivers last.
# Missing optional modules are skipped, but a small must-have set is enforced.
MODULES=(
  # Generic dependencies / GKI wireless stack
  "net/rfkill/rfkill.ko"
  "lib/crypto/libarc4.ko"
  "lib/crc-itu-t.ko"
  "lib/crc-ccitt.ko"
  "drivers/misc/eeprom/eeprom_93cx6.ko"
  "net/wireless/cfg80211.ko"
  "net/mac80211/mac80211.ko"

  # USB Ethernet / USB modem networking
  "drivers/net/mii.ko"
  "drivers/usb/class/cdc-wdm.ko"
  "drivers/net/phy/smsc.ko"
  "drivers/net/usb/usbnet.ko"
  "drivers/net/usb/cdc_ether.ko"
  "drivers/net/usb/cdc_ncm.ko"
  "drivers/net/usb/cdc_eem.ko"
  "drivers/net/usb/rndis_host.ko"
  "drivers/net/usb/asix.ko"
  "drivers/net/usb/ax88179_178a.ko"
  "drivers/net/usb/r8152.ko"
  "drivers/net/usb/r8153_ecm.ko"
  "drivers/net/usb/rtl8150.ko"
  "drivers/net/usb/aqc111.ko"
  "drivers/net/usb/smsc75xx.ko"
  "drivers/net/usb/smsc95xx.ko"
  "drivers/net/usb/cdc_mbim.ko"
  "drivers/net/usb/qmi_wwan.ko"

  # Optional virtual netdevs / tc / nftables modules
  "drivers/net/macvlan.ko"
  "drivers/net/ipvlan/ipvlan.ko"
  "net/sched/sch_cake.ko"
  "net/sched/cls_flower.ko"
  "net/netfilter/nf_tables.ko"
  "net/netfilter/nft_ct.ko"
  "net/netfilter/nft_nat.ko"
  "net/netfilter/nft_chain_nat.ko"
  "net/netfilter/nft_masq.ko"
  "net/netfilter/nft_redir.ko"
  "net/netfilter/nft_socket.ko"
  "net/netfilter/nft_tproxy.ko"
  "net/packet/af_packet_diag.ko"
  "net/unix/unix_diag.ko"
  "net/netlink/netlink_diag.ko"

  # Atheros / Qualcomm USB Wi-Fi
  "drivers/net/wireless/ath/ath.ko"
  "drivers/net/wireless/ath/ath9k/ath9k_hw.ko"
  "drivers/net/wireless/ath/ath9k/ath9k_common.ko"
  "drivers/net/wireless/ath/ath9k/ath9k_htc.ko"
  "drivers/net/wireless/ath/carl9170/carl9170.ko"

  # Ralink / MediaTek old USB Wi-Fi
  "drivers/net/wireless/ralink/rt2x00/rt2x00lib.ko"
  "drivers/net/wireless/ralink/rt2x00/rt2x00usb.ko"
  "drivers/net/wireless/ralink/rt2x00/rt2800lib.ko"
  "drivers/net/wireless/ralink/rt2x00/rt2800usb.ko"
  "drivers/net/wireless/ralink/rt2x00/rt73usb.ko"

  # Realtek mainline USB Wi-Fi
  "drivers/net/wireless/realtek/rtl818x/rtl8187/rtl8187.ko"
  "drivers/net/wireless/realtek/rtl8xxxu/rtl8xxxu.ko"

  # MediaTek mt76 USB Wi-Fi
  "drivers/net/wireless/mediatek/mt76/mt76.ko"
  "drivers/net/wireless/mediatek/mt76/mt76-usb.ko"
  "drivers/net/wireless/mediatek/mt76/mt76x02-lib.ko"
  "drivers/net/wireless/mediatek/mt76/mt76x02-usb.ko"
  "drivers/net/wireless/mediatek/mt76/mt76x0/mt76x0-common.ko"
  "drivers/net/wireless/mediatek/mt76/mt76x0/mt76x0u.ko"
  "drivers/net/wireless/mediatek/mt76/mt76x2/mt76x2-common.ko"
  "drivers/net/wireless/mediatek/mt76/mt76x2/mt76x2u.ko"
  "drivers/net/wireless/mediatek/mt7601u/mt7601u.ko"
  "drivers/net/wireless/mediatek/mt76/mt76-connac-lib.ko"
  "drivers/net/wireless/mediatek/mt76/mt7615/mt7615-common.ko"
  "drivers/net/wireless/mediatek/mt76/mt7615/mt7663-usb-sdio-common.ko"
  "drivers/net/wireless/mediatek/mt76/mt7615/mt7663u.ko"
  "drivers/net/wireless/mediatek/mt76/mt7921/mt7921-common.ko"
  "drivers/net/wireless/mediatek/mt76/mt7921/mt7921u.ko"

  # ZyDAS USB Wi-Fi
  "drivers/net/wireless/zydas/zd1211rw/zd1211rw.ko"
)

REQUIRED=(
  "net/wireless/cfg80211.ko"
  "net/mac80211/mac80211.ko"
  "drivers/net/wireless/ath/ath9k/ath9k_htc.ko"
  "drivers/net/wireless/ralink/rt2x00/rt2800usb.ko"
  "drivers/net/wireless/realtek/rtl818x/rtl8187/rtl8187.ko"
  "drivers/net/wireless/realtek/rtl8xxxu/rtl8xxxu.ko"
  "drivers/net/wireless/mediatek/mt7601u/mt7601u.ko"
  "drivers/net/wireless/mediatek/mt76/mt76x2/mt76x2u.ko"
  "drivers/net/wireless/zydas/zd1211rw/zd1211rw.ko"
)

find_module() {
  local rel="$1" base
  base="$(basename "$rel")"
  find "$OUT_ROOT" -type f -name "$base" -path "*/$rel" 2>/dev/null | head -1
}

copied=0
missing_required=0
: > "$DEST/modules.load"
for rel in "${MODULES[@]}"; do
  src="$(find_module "$rel" || true)"
  if [ -z "$src" ]; then
    for req in "${REQUIRED[@]}"; do
      if [ "$rel" = "$req" ]; then
        echo "ERROR: required Kurumi network module not found in build out: $rel" >&2
        missing_required=1
      fi
    done
    continue
  fi
  dst="$LIB/$(basename "$rel")"
  cp -f "$src" "$dst"
  echo "$(basename "$rel")" >> "$DEST/modules.load"
  copied=$((copied + 1))
  echo "copied network module: $rel"
done

[ "$missing_required" = 0 ] || exit 1
[ "$copied" -gt 0 ] || { echo 'ERROR: no network modules copied' >&2; exit 1; }

cat > "$DEST/README.txt" <<'TXT'
Kurumi Network Pack modules

These .ko files are built against the same Kurumi kernel release and are loaded
by /data/adb/modules/kurumi_network/service.sh. Firmware blobs are not bundled;
put device firmware in a firmware path visible to Android if your adapter needs it.
TXT

echo "OK: copied $copied Kurumi Network Pack module(s) into $DEST"
