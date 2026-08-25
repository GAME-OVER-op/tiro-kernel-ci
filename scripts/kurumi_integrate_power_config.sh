#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
COMMON="$ROOT/common"
MSM="$ROOT/msm-kernel"
CDEF="$COMMON/arch/arm64/configs/gki_defconfig"
MDEF="$MSM/arch/arm64/configs/gki_defconfig"
FRAG="$MSM/arch/arm64/configs/vendor/pineapple_GKI.config"

[ -f "$CDEF" ] || { echo "ERROR: missing common gki_defconfig: $CDEF" >&2; exit 1; }
[ -f "$MDEF" ] || { echo "ERROR: missing msm gki_defconfig: $MDEF" >&2; exit 1; }
[ -f "$FRAG" ] || { echo "ERROR: missing pineapple_GKI.config: $FRAG" >&2; exit 1; }

has_kconfig_symbol() {
  local sym="$1"
  grep -Rqs "^[[:space:]]*config[[:space:]]\+$sym\b" \
    "$COMMON"/init "$COMMON"/kernel "$COMMON"/mm "$COMMON"/lib "$COMMON"/drivers "$COMMON"/arch 2>/dev/null
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

insert_symbol_y_after() {
  local file="$1"
  local sym="$2"
  local anchor="$3"

  # Kleaf's common GKI KernelConfig runs `savedefconfig` and requires the
  # checked-in gki_defconfig to already be in canonical Kconfig order.  Do not
  # append new common-GKI symbols to EOF: savedefconfig moves them and the
  # byte-for-byte check fails.
  drop_symbol_lines "$file" "$sym"

  if ! grep -qF "$anchor" "$file"; then
    echo "ERROR: canonical insertion anchor for CONFIG_${sym} not found: ${anchor}" >&2
    exit 1
  fi

  python3 - "$file" "$anchor" "CONFIG_${sym}=y" <<'PY_INSERT'
from pathlib import Path
import sys

path = Path(sys.argv[1])
anchor = sys.argv[2]
line = sys.argv[3]
text = path.read_text()
needle = anchor + "\n"
if needle not in text:
    raise SystemExit(f"ERROR: insertion anchor disappeared: {anchor}")
text = text.replace(needle, needle + line + "\n", 1)
path.write_text(text)
PY_INSERT
}

set_symbol_notset_or_drop() {
  local file="$1"
  local sym="$2"
  local mode="${3:-notset}"
  local had=0
  if grep -qE "^(CONFIG_${sym}=|# CONFIG_${sym} is not set$)" "$file"; then
    had=1
  fi
  drop_symbol_lines "$file" "$sym"
  if [ "$mode" = "notset" ] && [ "$had" = 1 ]; then
    printf '# CONFIG_%s is not set\n' "$sym" >> "$file"
  fi
}

# Actual flashed Image is built from common/. Keep this strict and conservative.
# KASAN is intentionally NOT disabled: QCOM GKI KMI expects kasan_flag_enabled.
sed -i \
  -e '/^CONFIG_MODULE_SIG_PROTECT=y/d' \
  -e '/^CONFIG_PM_DEBUG=y/d' \
  -e '/^CONFIG_PM_ADVANCED_DEBUG=y/d' \
  -e '/^CONFIG_THERMAL_STATISTICS=y/d' \
  -e '/^CONFIG_THERMAL_EMULATION=y/d' \
  -e '/^CONFIG_UBSAN=y/d' \
  -e '/^CONFIG_UBSAN_/d' \
  -e '/^# CONFIG_UBSAN_.* is not set$/d' \
  "$CDEF"

# Release/debug cleanup for msm-kernel base defconfig. The strict QCOM merged
# defconfig gate prefers explicit not-set for visible symbols there.
set_symbol_notset_or_drop "$MDEF" MODULE_SIG_PROTECT notset
set_symbol_notset_or_drop "$MDEF" PM_DEBUG notset
# PM_ADVANCED_DEBUG depends on PM_DEBUG; once PM_DEBUG is off it becomes hidden.
set_symbol_notset_or_drop "$MDEF" PM_ADVANCED_DEBUG drop
set_symbol_notset_or_drop "$MDEF" THERMAL_STATISTICS notset
set_symbol_notset_or_drop "$MDEF" THERMAL_EMULATION notset
set_symbol_notset_or_drop "$MDEF" UBSAN notset
sed -i -e '/^CONFIG_UBSAN_/d' -e '/^# CONFIG_UBSAN_.* is not set$/d' "$MDEF"

# Autonomy symbols that are safe and should land in the real common GKI Image.
if has_kconfig_symbol WQ_POWER_EFFICIENT_DEFAULT; then
  insert_symbol_y_after "$CDEF" WQ_POWER_EFFICIENT_DEFAULT '# CONFIG_PM_WAKELOCKS_GC is not set'
else
  echo 'WARN: CONFIG_WQ_POWER_EFFICIENT_DEFAULT not present in this common tree'
fi

if has_kconfig_symbol LRU_GEN; then
  insert_symbol_y_after "$CDEF" LRU_GEN 'CONFIG_USERFAULTFD=y'
  if has_kconfig_symbol LRU_GEN_ENABLED; then
    # Insert after LRU_GEN so the pair matches savedefconfig's canonical order.
    insert_symbol_y_after "$CDEF" LRU_GEN_ENABLED 'CONFIG_LRU_GEN=y'
  fi
else
  echo 'WARN: CONFIG_LRU_GEN not present in this common tree'
fi

# RCU lazy callbacks reduce idle callback churn. Do not write an explicit
# '# CONFIG_RCU_LAZY_DEFAULT_OFF is not set' into common gki_defconfig because
# savedefconfig-style checks may omit default-n lines. Removing DEFAULT_OFF is
# enough when RCU_LAZY is enabled.
if has_kconfig_symbol RCU_LAZY; then
  insert_symbol_y_after "$CDEF" RCU_LAZY 'CONFIG_RCU_NOCB_CPU=y'
  drop_symbol_lines "$CDEF" RCU_LAZY_DEFAULT_OFF
else
  echo 'WARN: CONFIG_RCU_LAZY not present in this common tree'
fi

# Keep the vendor fragment additive for compatibility with existing workflow.
# Duplicates are removed first so repeated runs stay stable.
drop_symbol_lines "$FRAG" WQ_POWER_EFFICIENT_DEFAULT LRU_GEN LRU_GEN_ENABLED RCU_LAZY RCU_LAZY_DEFAULT_OFF
sed -i '/^# === Kurumi: safe autonomy additions, final Image is verified after build ===$/d' "$FRAG"
# Normalize trailing blank lines so rerunning the helper is byte-for-byte stable.
python3 - "$FRAG" <<'PY_FRAG_CLEAN'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text().rstrip() + "\n"
p.write_text(s)
PY_FRAG_CLEAN
{
  echo ''
  echo '# === Kurumi: safe autonomy additions, final Image is verified after build ==='
  echo 'CONFIG_WQ_POWER_EFFICIENT_DEFAULT=y'
  echo 'CONFIG_LRU_GEN=y'
  echo 'CONFIG_LRU_GEN_ENABLED=y'
  echo 'CONFIG_RCU_LAZY=y'
} >> "$FRAG"

# Hard guards for the dangerous/known-expensive active options we deliberately remove.
if grep -qE '^(CONFIG_MODULE_SIG_PROTECT|CONFIG_UBSAN|CONFIG_PM_DEBUG|CONFIG_THERMAL_STATISTICS|CONFIG_THERMAL_EMULATION)=y' "$CDEF"; then
  echo 'ERROR: common gki_defconfig still contains active release-disabled symbols' >&2
  grep -nE 'MODULE_SIG_PROTECT|UBSAN|PM_DEBUG|THERMAL_STATISTICS|THERMAL_EMULATION' "$CDEF" >&2 || true
  exit 1
fi

if grep -q '^CONFIG_RCU_LAZY_DEFAULT_OFF=y' "$CDEF"; then
  echo 'ERROR: CONFIG_RCU_LAZY_DEFAULT_OFF=y survived in common gki_defconfig' >&2
  exit 1
fi

if ! grep -q '^CONFIG_KASAN=y' "$CDEF"; then
  echo 'ERROR: CONFIG_KASAN must stay enabled for QCOM GKI KMI compatibility' >&2
  exit 1
fi

echo 'OK: Kurumi safe autonomy kernel config integrated.'
echo '--- common autonomy/debug config context ---'
grep -nE 'KURUMI_SCREEN_STATE|WQ_POWER_EFFICIENT_DEFAULT|LRU_GEN|RCU_LAZY|RCU_LAZY_DEFAULT_OFF|MODULE_SIG_PROTECT|PM_DEBUG|THERMAL_STATISTICS|THERMAL_EMULATION|UBSAN|KASAN' "$CDEF" || true
