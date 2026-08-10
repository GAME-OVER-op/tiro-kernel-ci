#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
COMMON="$ROOT/common"
MSM="$ROOT/msm-kernel"
CDEF="$COMMON/arch/arm64/configs/gki_defconfig"
FRAG="$MSM/arch/arm64/configs/vendor/pineapple_GKI.config"

[ -f "$CDEF" ] || { echo "ERROR: missing common gki_defconfig: $CDEF" >&2; exit 1; }
[ -f "$FRAG" ] || { echo "ERROR: missing pineapple_GKI.config: $FRAG" >&2; exit 1; }

has_symbol() {
  local sym="$1"
  grep -Rqs "^[[:space:]]*\(menuconfig\|config\)[[:space:]]\+$sym\b" \
    "$COMMON" "$MSM" 2>/dev/null
}

drop_symbol_lines() {
  local file="$1"; shift
  local sym
  for sym in "$@"; do
    sed -i \
      -e "/^CONFIG_${sym}=.*/d" \
      -e "/^# CONFIG_${sym} is not set$/d" \
      "$file"
  done
}

append_if_symbol() {
  local file="$1" sym="$2" val="$3"
  if has_symbol "$sym"; then
    drop_symbol_lines "$file" "$sym"
    printf 'CONFIG_%s=%s\n' "$sym" "$val" >> "$file"
  else
    echo "WARN: CONFIG_${sym} is not present in this tree; skipped" >&2
  fi
}

append_notset_if_symbol() {
  local file="$1" sym="$2"
  if has_symbol "$sym"; then
    drop_symbol_lines "$file" "$sym"
    printf '# CONFIG_%s is not set\n' "$sym" >> "$file"
  fi
}

# Keep common gki_defconfig savedefconfig-safe: only insert the small set that
# this project already knows how to place safely. The big network pack is kept
# in the msm vendor fragment as additive =m/=y options so Kleaf can resolve it
# through the normal pineapple config merge without perturbing common order.
sed -i -e '/^# === Kurumi Network Pack: USB Wi-Fi dongles + network tooling ===$/d' "$FRAG"

for sym in \
  USB_NET_CDCETHER USB_NET_CDC_NCM USB_NET_RNDIS_HOST USB_NET_AX8817X \
  USB_NET_AX88179_178A USB_RTL8152 USB_NET_SMSC75XX USB_NET_SMSC95XX \
  USB_NET_CDC_MBIM USB_NET_QMI_WWAN \
  CFG80211 MAC80211 CFG80211_WEXT WLAN_VENDOR_ATH ATH9K_HTC CARL9170 \
  WLAN_VENDOR_RALINK RT2X00 RT73USB RT2800USB RT2800USB_RT33XX \
  RT2800USB_RT35XX RT2800USB_RT3573 RT2800USB_RT53XX RT2800USB_RT55XX \
  WLAN_VENDOR_REALTEK RTL8187 RTL8XXXU RTL8XXXU_UNTESTED \
  WLAN_VENDOR_MEDIATEK MT7601U MT76x0U MT76x2U MT7663U MT7921U \
  WLAN_VENDOR_ZYDAS ZD1211RW \
  TUN VETH BRIDGE MACVLAN IPVLAN DUMMY IFB VLAN_8021Q WIREGUARD \
  NET_SCH_CAKE NET_SCH_FQ_CODEL NET_SCH_FQ NET_SCH_TBF NET_SCH_INGRESS \
  NET_CLS_U32 NET_CLS_FW NET_CLS_FLOWER NET_ACT_MIRRED NET_ACT_POLICE \
  NETFILTER_XT_TARGET_TPROXY NETFILTER_XT_MATCH_SOCKET NETFILTER_XT_MATCH_OWNER \
  NETFILTER_XT_TARGET_MARK NETFILTER_XT_MATCH_MARK NETFILTER_XT_TARGET_CONNMARK \
  NETFILTER_XT_MATCH_CONNMARK NETFILTER_XT_TARGET_REDIRECT NETFILTER_XT_TARGET_MASQUERADE \
  NETFILTER_XTABLES NETFILTER_ADVANCED NF_CONNTRACK NF_CONNTRACK_MARK NF_NAT NF_TABLES NF_TABLES_INET NF_TABLES_IPV4 NF_TABLES_IPV6 \
  NETFILTER_XT_MATCH_MULTIPORT NETFILTER_XT_MATCH_COMMENT NFT_TPROXY \
  NFT_SOCKET NFT_NAT NFT_MASQ NFT_REDIR NFT_CT PACKET PACKET_DIAG \
  UNIX_DIAG INET_DIAG INET_TCP_DIAG SOCK_DIAG NETLINK_DIAG BPF BPF_SYSCALL \
  CGROUP_BPF; do
  drop_symbol_lines "$FRAG" "$sym"
done

{
  echo ''
  echo '# === Kurumi Network Pack: USB Wi-Fi dongles + network tooling ==='
} >> "$FRAG"

# USB Ethernet / modem host adapters. Most are modules so they do not cost
# runtime power until loaded or a matching USB device is attached.
append_if_symbol "$FRAG" USB_NET_CDCETHER m
append_if_symbol "$FRAG" USB_NET_CDC_NCM m
append_if_symbol "$FRAG" USB_NET_RNDIS_HOST m
append_if_symbol "$FRAG" USB_NET_AX8817X m
append_if_symbol "$FRAG" USB_NET_AX88179_178A m
append_if_symbol "$FRAG" USB_RTL8152 m
append_if_symbol "$FRAG" USB_NET_SMSC75XX m
append_if_symbol "$FRAG" USB_NET_SMSC95XX m
append_if_symbol "$FRAG" USB_NET_CDC_MBIM m
append_if_symbol "$FRAG" USB_NET_QMI_WWAN m

# Core wireless stack and old iwconfig compatibility for Kali/chroot tools.
append_if_symbol "$FRAG" CFG80211 m
append_notset_if_symbol "$FRAG" CFG80211_CRDA_SUPPORT
append_if_symbol "$FRAG" MAC80211 m
append_if_symbol "$FRAG" CFG80211_WEXT y

# Mainline USB Wi-Fi drivers. Out-of-tree 88xxau/88x2bu are intentionally not
# vendored here; this pack enables everything useful already present in the
# Android 14 / Linux 6.1 tree.
append_if_symbol "$FRAG" WLAN_VENDOR_ATH y
append_if_symbol "$FRAG" ATH9K_HTC m
append_if_symbol "$FRAG" CARL9170 m

append_if_symbol "$FRAG" WLAN_VENDOR_RALINK y
append_if_symbol "$FRAG" RT2X00 m
append_if_symbol "$FRAG" RT73USB m
append_if_symbol "$FRAG" RT2800USB m
append_if_symbol "$FRAG" RT2800USB_RT33XX y
append_if_symbol "$FRAG" RT2800USB_RT35XX y
append_if_symbol "$FRAG" RT2800USB_RT3573 y
append_if_symbol "$FRAG" RT2800USB_RT53XX y
append_if_symbol "$FRAG" RT2800USB_RT55XX y
# Keep unknown IDs disabled: it can bind unstable devices incorrectly.
append_notset_if_symbol "$FRAG" RT2800USB_UNKNOWN

append_if_symbol "$FRAG" WLAN_VENDOR_REALTEK y
append_if_symbol "$FRAG" RTL8187 m
append_if_symbol "$FRAG" RTL8XXXU m
append_if_symbol "$FRAG" RTL8XXXU_UNTESTED y

append_if_symbol "$FRAG" WLAN_VENDOR_MEDIATEK y
append_if_symbol "$FRAG" MT7601U m
append_if_symbol "$FRAG" MT76x0U m
append_if_symbol "$FRAG" MT76x2U m
append_if_symbol "$FRAG" MT7663U m
append_if_symbol "$FRAG" MT7921U m

append_if_symbol "$FRAG" WLAN_VENDOR_ZYDAS y
append_if_symbol "$FRAG" ZD1211RW m

# Network lab / routing / VPN / container primitives. Many are already y in GKI;
# keeping them here makes the final config explicit and auditable.
append_if_symbol "$FRAG" TUN y
append_if_symbol "$FRAG" VETH y
append_if_symbol "$FRAG" BRIDGE y
append_if_symbol "$FRAG" MACVLAN m
append_if_symbol "$FRAG" IPVLAN m
append_if_symbol "$FRAG" DUMMY y
append_if_symbol "$FRAG" IFB y
append_if_symbol "$FRAG" VLAN_8021Q m
append_if_symbol "$FRAG" WIREGUARD y

# Traffic control / shaping.
append_if_symbol "$FRAG" NET_SCH_CAKE m
append_if_symbol "$FRAG" NET_SCH_FQ_CODEL y
append_if_symbol "$FRAG" NET_SCH_FQ y
append_if_symbol "$FRAG" NET_SCH_TBF y
append_if_symbol "$FRAG" NET_SCH_INGRESS y
append_if_symbol "$FRAG" NET_CLS_U32 y
append_if_symbol "$FRAG" NET_CLS_FW y
append_if_symbol "$FRAG" NET_CLS_FLOWER m
append_if_symbol "$FRAG" NET_ACT_MIRRED y
append_if_symbol "$FRAG" NET_ACT_POLICE y

# iptables/nftables helpers used by transparent proxying and routing rules.
# QCOM's strict check_merged_defconfig rejects fragment entries whose Kconfig
# dependencies do not stick. NFT_NAT in particular requires NF_CONNTRACK and
# NF_TABLES_IPV4 or NF_TABLES_IPV6. Keep the nftables core built-in and leaf
# expressions as modules so nft NAT/redirect/tproxy can resolve cleanly without
# losing the classic xtables path used by existing Kurumi routing.
append_if_symbol "$FRAG" NETFILTER_ADVANCED y
append_if_symbol "$FRAG" NETFILTER_XTABLES y
append_if_symbol "$FRAG" NF_CONNTRACK y
append_if_symbol "$FRAG" NF_CONNTRACK_MARK y
append_if_symbol "$FRAG" NF_NAT y
append_if_symbol "$FRAG" NF_TABLES y
append_if_symbol "$FRAG" NF_TABLES_INET y
append_if_symbol "$FRAG" NF_TABLES_IPV4 y
append_if_symbol "$FRAG" NF_TABLES_IPV6 y

append_if_symbol "$FRAG" NETFILTER_XT_TARGET_TPROXY y
append_if_symbol "$FRAG" NETFILTER_XT_MATCH_SOCKET y
append_if_symbol "$FRAG" NETFILTER_XT_MATCH_OWNER y
append_if_symbol "$FRAG" NETFILTER_XT_TARGET_MARK y
append_if_symbol "$FRAG" NETFILTER_XT_MATCH_MARK y
append_if_symbol "$FRAG" NETFILTER_XT_TARGET_CONNMARK y
append_if_symbol "$FRAG" NETFILTER_XT_MATCH_CONNMARK y
append_if_symbol "$FRAG" NETFILTER_XT_TARGET_REDIRECT y
append_if_symbol "$FRAG" NETFILTER_XT_TARGET_MASQUERADE y
append_if_symbol "$FRAG" NETFILTER_XT_MATCH_MULTIPORT y
append_if_symbol "$FRAG" NETFILTER_XT_MATCH_COMMENT y
append_if_symbol "$FRAG" NFT_TPROXY m
append_if_symbol "$FRAG" NFT_SOCKET m
append_if_symbol "$FRAG" NFT_CT m
append_if_symbol "$FRAG" NFT_NAT m
append_if_symbol "$FRAG" NFT_MASQ m
append_if_symbol "$FRAG" NFT_REDIR m

# Diagnostics / tcpdump / ss / conntrack-friendly visibility.
append_if_symbol "$FRAG" PACKET y
append_if_symbol "$FRAG" PACKET_DIAG m
append_if_symbol "$FRAG" UNIX_DIAG m
append_if_symbol "$FRAG" INET_DIAG y
append_if_symbol "$FRAG" INET_TCP_DIAG y
append_if_symbol "$FRAG" SOCK_DIAG y
append_if_symbol "$FRAG" NETLINK_DIAG m
append_if_symbol "$FRAG" BPF y
append_if_symbol "$FRAG" BPF_SYSCALL y
append_if_symbol "$FRAG" CGROUP_BPF y

# Guard the must-have USB Wi-Fi symbols before the expensive build starts.
for need in CFG80211 MAC80211 ATH9K_HTC RT2800USB RTL8187 RTL8XXXU MT7601U MT76x2U ZD1211RW; do
  grep -qE "^CONFIG_${need}=" "$FRAG" || { echo "ERROR: CONFIG_${need} was not written to $FRAG" >&2; exit 1; }
done

echo 'OK: Kurumi Network Pack integrated into pineapple vendor fragment.'
echo '--- Kurumi Network Pack config tail ---'
tail -n 90 "$FRAG"
