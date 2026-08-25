#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
COMMON="$ROOT/common"
SRC_DIR="${GITHUB_WORKSPACE:-$PWD}/kernel/kurumi"

[ -d "$COMMON" ] || { echo "ERROR: common tree not found at $COMMON" >&2; exit 1; }
[ -f "$SRC_DIR/kurumi_screen_state.c" ] || { echo "ERROR: kurumi screen source missing: $SRC_DIR" >&2; exit 1; }

install -D -m0644 "$SRC_DIR/kurumi_screen_state.c" "$COMMON/drivers/misc/kurumi_screen_state.c"
install -D -m0644 "$SRC_DIR/kurumi_screen_state.h" "$COMMON/include/linux/kurumi_screen_state.h"

KCONF="$COMMON/drivers/misc/Kconfig"
MK="$COMMON/drivers/misc/Makefile"
BL="$COMMON/drivers/video/backlight/backlight.c"
CDEF="$COMMON/arch/arm64/configs/gki_defconfig"

if ! grep -q 'config KURUMI_SCREEN_STATE' "$KCONF"; then
  python3 - "$KCONF" <<'PY_KCONF'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
block = '''
config KURUMI_SCREEN_STATE
	bool "Kurumi screen state sysfs bridge"
	depends on BACKLIGHT_CLASS_DEVICE
	help
	  Expose a tiny read-only /sys/kernel/kurumi_screen interface for
	  userspace power/profile daemons. It mirrors backlight-derived screen
	  state and avoids expensive Android framework polling.
'''
idx = s.rfind('\nendmenu')
if idx >= 0:
    s = s[:idx] + block + s[idx:]
else:
    s += block
p.write_text(s)
PY_KCONF
fi

if ! grep -q 'kurumi_screen_state.o' "$MK"; then
  printf '\nobj-$(CONFIG_KURUMI_SCREEN_STATE) += kurumi_screen_state.o\n' >> "$MK"
fi

python3 - "$BL" <<'PY_BL'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
if '#include <linux/kurumi_screen_state.h>' not in s:
    anchor = '#include <linux/backlight.h>\n'
    if anchor not in s:
        raise SystemExit('ERROR: backlight.h include anchor not found')
    s = s.replace(anchor, anchor + '#include <linux/kurumi_screen_state.h>\n', 1)
if 'kurumi_screen_state_from_backlight(bd);' not in s:
    s = s.replace('sysfs_notify(&bd->dev.kobj, NULL, "actual_brightness");',
                  'sysfs_notify(&bd->dev.kobj, NULL, "actual_brightness");\n\tkurumi_screen_state_from_backlight(bd);', 1)
# Also catch blank/suspend/resume transitions that call update_status() but do not
# necessarily generate a userspace brightness event.
if 'KURUMI_SCREEN_HOOK_UPDATE_STATUS' not in s:
    s = s.replace('backlight_update_status(bd);',
                  'backlight_update_status(bd);\n\t\t\t/* KURUMI_SCREEN_HOOK_UPDATE_STATUS */\n\t\t\tkurumi_screen_state_from_backlight(bd);')
p.write_text(s)
PY_BL

# Keep common/arch/arm64/configs/gki_defconfig in savedefconfig order.  Kleaf
# compares the generated defconfig against this file exactly; appending this
# symbol (or a custom comment) at EOF makes the strict KernelConfig gate fail.
sed -i \
  -e '/^CONFIG_KURUMI_SCREEN_STATE=.*/d' \
  -e '/^# CONFIG_KURUMI_SCREEN_STATE is not set$/d' \
  -e '/^# Kurumi: cheap kernel screen state for userspace profile daemon$/d' \
  "$CDEF"

if ! grep -q '^CONFIG_UID_SYS_STATS=y' "$CDEF"; then
  echo 'ERROR: canonical insertion anchor CONFIG_UID_SYS_STATS=y not found in common gki_defconfig' >&2
  exit 1
fi
python3 - "$CDEF" <<'PY_DEFCONFIG'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
anchor = 'CONFIG_UID_SYS_STATS=y\n'
if anchor not in s:
    raise SystemExit('ERROR: CONFIG_UID_SYS_STATS=y insertion anchor disappeared')
s = s.replace(anchor, anchor + 'CONFIG_KURUMI_SCREEN_STATE=y\n', 1)
p.write_text(s)
PY_DEFCONFIG

grep -q 'kurumi_screen_state_from_backlight' "$BL" || { echo 'ERROR: backlight hook missing' >&2; exit 1; }
grep -q '^CONFIG_KURUMI_SCREEN_STATE=y' "$CDEF" || { echo 'ERROR: CONFIG_KURUMI_SCREEN_STATE not enabled' >&2; exit 1; }
echo 'OK: Kurumi screen-state sysfs bridge integrated into common kernel tree.'
