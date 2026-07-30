#!/system/bin/sh

MODDIR="${0%/*}"

setsid "$MODDIR/kurumi" 2>&1 </dev/null &

exit 0
