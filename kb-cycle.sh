#!/usr/bin/env bash
# Cycle ASUS KB backlight between off and max using state file in ~/Scripts
set -euo pipefail

STATE="$HOME/Scripts/kb-level.state"
LOCK="$STATE.lock"
MAIN="$HOME/Scripts/duo-usb-brightness.sh"

# serialize concurrent invocations
exec 9>"$LOCK"
flock -x 9

# ensure state file exists and is sane
if [[ ! -f "$STATE" ]] || ! grep -qE '^[0-3]$' "$STATE"; then
  echo "0" > "$STATE"
fi

level="$(cat "$STATE")"

# if it's off, go to max. Otherwise, go to off.
if [[ "$level" -eq 0 ]]; then
  next=3
else
  next=0
fi

# set brightness
"$MAIN" "$next" || true

# and store next level
echo "$next" > "$STATE"

if [[ "$next" -eq 0 ]]; then
    echo "Set brightness to off."
else
    echo "Set brightness to max."
fi
