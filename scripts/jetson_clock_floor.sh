#!/bin/bash
# jetson_clock_floor.sh (hardened) - keep the system clock from sitting in the
# past on a battery-less carrier. A 1970 clock breaks the Axelera Voyager
# runtime's Metis bring-up (NPU gets no MSI; dmesg spams `axl ... IRQ MSI
# timeout`). See docs/TROUBLESHOOTING.md H-13 and docs/OPERATIONS.md.
#   apply: set the clock to max(saved floor, HARD_MIN) if currently earlier, and
#          write it to the RTC so nothing later (hctosys) drags it back to 1970.
#   save : persist the current time ONLY if sane (>=2023) and newer (ratchet up),
#          so a 1970 clock can never corrupt the floor (the bug that bit 06-27).
set -u
STAMP=/var/lib/clock-floor.epoch
HARD_MIN=1735689600     # 2025-01-01 UTC: absolute floor; the bake seeds a newer one
SANE=1700000000         # ~2023-11; reject anything older as bogus when saving
_int(){ case "$1" in ''|*[!0-9]*) echo 0;; *) echo "$1";; esac; }
case "${1:-}" in
  apply)
    f=$HARD_MIN
    if [ -r "$STAMP" ]; then s=$(_int "$(cat "$STAMP" 2>/dev/null)"); [ "$s" -gt "$f" ] && f=$s; fi
    now=$(date +%s)
    if [ "$f" -gt "$now" ]; then
      date -u -s "@$f" >/dev/null && hwclock -w 2>/dev/null
      logger -t clock-floor "floored clock $now -> $f"
    fi ;;
  save)
    now=$(date +%s)
    [ "$now" -ge "$SANE" ] || exit 0
    cur=$(_int "$(cat "$STAMP" 2>/dev/null)")
    [ "$now" -gt "$cur" ] && echo "$now" > "$STAMP" ;;
  *) echo "usage: jetson_clock_floor.sh {apply|save}" >&2; exit 2 ;;
esac
