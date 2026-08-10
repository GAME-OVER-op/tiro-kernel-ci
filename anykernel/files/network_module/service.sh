#!/system/bin/sh

MODDIR="${0%/*}"
MODLIB="$MODDIR/lib/modules"
LOADLIST="$MODDIR/modules.load"
LOG="$MODDIR/kurumi_network.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) $*" >> "$LOG" 2>/dev/null
}

module_loaded() {
  local name="$1"
  name="${name%.ko}"
  name="$(echo "$name" | tr '-' '_')"
  grep -q "^${name} " /proc/modules 2>/dev/null
}

load_one() {
  local ko="$1" path="$MODLIB/$ko"
  [ -f "$path" ] || return 0
  module_loaded "$ko" && return 0
  insmod "$path" >/dev/null 2>&1 && { log "loaded $ko"; return 0; }
  log "WARN: failed to load $ko"
  return 0
}

[ -d "$MODLIB" ] || exit 0
[ -f "$LOADLIST" ] || exit 0

log "starting Kurumi Network Pack module loader"
while IFS= read -r ko; do
  case "$ko" in
    ''|'#'*) continue ;;
  esac
  load_one "$ko"
done < "$LOADLIST"
log "Kurumi Network Pack loader finished"

exit 0
