#!/bin/bash
# jetson_clock_floor.sh - keep the system clock from sitting in the past.
# The p3768 carrier has NO RTC battery, so a full power-off resets the clock to
# 1970. A 1970 clock breaks the Axelera Voyager runtime's Metis bring-up
# (cert/time + ZIP<1980 failures) -> the NPU never gets MSI interrupts and dmesg
# spams `axl ... IRQ MSI timeout`. This floors the clock to the last-known-good
# time early at boot (before axsystemserver), and saves it every 15 min while up.
# See docs/TROUBLESHOOTING.md H-13 and docs/OPERATIONS.md.
set -u
STAMP=/var/lib/clock-floor.epoch
case "${1:-}" in
  apply)
    [ -r "$STAMP" ] || exit 0
    floor=$(cat "$STAMP" 2>/dev/null || echo 0); now=$(date +%s)
    if [ "${floor:-0}" -gt "$now" ]; then
      date -u -s "@$floor" >/dev/null && logger -t clock-floor "advanced clock $now -> floor $floor"
    fi ;;
  save) date +%s > "$STAMP" ;;
  *) echo "usage: jetson_clock_floor.sh {apply|save}" >&2; exit 2 ;;
esac
