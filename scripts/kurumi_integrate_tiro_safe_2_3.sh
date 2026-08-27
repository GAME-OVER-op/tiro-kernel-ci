#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
COMMON="$ROOT/common"
MSM="$ROOT/msm-kernel"
CDEF="$COMMON/arch/arm64/configs/gki_defconfig"
MDEF="$MSM/arch/arm64/configs/gki_defconfig"

[ -f "$CDEF" ] || { echo "ERROR: missing common gki_defconfig: $CDEF" >&2; exit 1; }
[ -f "$MDEF" ] || { echo "ERROR: missing msm gki_defconfig: $MDEF" >&2; exit 1; }

has_kconfig_symbol() {
  local tree="$1" sym="$2"
  grep -Rqs "^[[:space:]]*config[[:space:]]\+$sym\b" \
    "$tree"/init "$tree"/kernel "$tree"/mm "$tree"/lib "$tree"/drivers "$tree"/arch 2>/dev/null
}

drop_symbol_lines() {
  local file="$1" sym="$2"
  sed -i \
    -e "/^CONFIG_${sym}=.*/d" \
    -e "/^# CONFIG_${sym} is not set$/d" \
    "$file"
}

insert_y_after() {
  local file="$1" sym="$2" anchor="$3"
  drop_symbol_lines "$file" "$sym"
  grep -qF "$anchor" "$file" || {
    echo "ERROR: canonical insertion anchor for CONFIG_${sym} not found in $file: $anchor" >&2
    exit 1
  }
  python3 - "$file" "$anchor" "CONFIG_${sym}=y" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
anchor = sys.argv[2]
line = sys.argv[3]
s = p.read_text()
needle = anchor + "\n"
if needle not in s:
    raise SystemExit(f"ERROR: insertion anchor disappeared: {anchor}")
s = s.replace(needle, needle + line + "\n", 1)
p.write_text(s)
PY
}

# Item 1 stays deliberately disabled. Enabling BLK_WBT changes struct request
# layout on this 6.1 tree and is not safe with the ROM's existing prebuilt
# vendor/vendor_dlkm module set.
if grep -q '^CONFIG_BLK_WBT=y' "$CDEF"; then
  echo 'ERROR: CONFIG_BLK_WBT=y is active in common GKI; refusing ABI-risky build.' >&2
  exit 1
fi

# Item 2: preserve PER_VMA_LOCK itself but remove only its developer statistics.
# common GKI savedefconfig omits the default-n line, so remove the explicit =y
# rather than appending a '# ... is not set' entry at EOF.
if has_kconfig_symbol "$COMMON" PER_VMA_LOCK_STATS; then
  drop_symbol_lines "$CDEF" PER_VMA_LOCK_STATS
else
  echo 'WARN: CONFIG_PER_VMA_LOCK_STATS not present in common tree'
fi

# Keep the msm-kernel configuration intent aligned. In this vendor base the
# visible symbol is represented canonically as an explicit not-set line.
if has_kconfig_symbol "$MSM" PER_VMA_LOCK_STATS; then
  drop_symbol_lines "$MDEF" PER_VMA_LOCK_STATS
  # Put it back where its former line lived canonically: after PER_VMA_LOCK if
  # that symbol is present, otherwise leave it absent (default n).
  if grep -q '^CONFIG_PER_VMA_LOCK=y' "$MDEF"; then
    python3 - "$MDEF" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = 'CONFIG_PER_VMA_LOCK=y\n'
line = '# CONFIG_PER_VMA_LOCK_STATS is not set\n'
if needle in s and line not in s:
    s = s.replace(needle, needle + line, 1)
p.write_text(s)
PY
  fi
fi

# Item 3: asynchronous SCSI discovery. Kleaf's strict common KernelConfig runs
# savedefconfig and requires this exact canonical order; CI previously showed
# SCSI_SCAN_ASYNC must follow BLK_DEV_SD.
if has_kconfig_symbol "$COMMON" SCSI_SCAN_ASYNC; then
  insert_y_after "$CDEF" SCSI_SCAN_ASYNC 'CONFIG_BLK_DEV_SD=y'
else
  echo 'ERROR: CONFIG_SCSI_SCAN_ASYNC missing from common tree' >&2
  exit 1
fi

if has_kconfig_symbol "$MSM" SCSI_SCAN_ASYNC && grep -q '^CONFIG_BLK_DEV_SD=y' "$MDEF"; then
  insert_y_after "$MDEF" SCSI_SCAN_ASYNC 'CONFIG_BLK_DEV_SD=y'
fi

# Guards.
if grep -q '^CONFIG_PER_VMA_LOCK_STATS=y' "$CDEF"; then
  echo 'ERROR: CONFIG_PER_VMA_LOCK_STATS=y survived in common GKI' >&2
  exit 1
fi
grep -q '^CONFIG_SCSI_SCAN_ASYNC=y' "$CDEF" || {
  echo 'ERROR: CONFIG_SCSI_SCAN_ASYNC=y did not land in common GKI' >&2
  exit 1
}
if grep -q '^CONFIG_BLK_WBT=y' "$CDEF"; then
  echo 'ERROR: CONFIG_BLK_WBT=y became active unexpectedly' >&2
  exit 1
fi

echo 'OK: Tiro safe config subset restored (items 2 + 3 only).'
echo '  1. BLK_WBT: kept disabled'
echo '  2. PER_VMA_LOCK_STATS: disabled'
echo '  3. SCSI_SCAN_ASYNC: enabled'
echo '--- common config context ---'
grep -nE 'BLK_WBT|PER_VMA_LOCK|SCSI|BLK_DEV_SD' "$CDEF" || true
