#!/usr/bin/env bash
set -euo pipefail

STATE="$HOME/Scripts/kb-level.state"
LOCK="$STATE.lock"

# serialize concurrent invocations
exec 9>"$LOCK"
flock -x 9

# ensure state file exists and is sane
if [[ ! -f "$STATE" ]] || ! grep -qE '^[0-3]$' "$STATE"; then
  echo "0" > "$STATE"
fi

# set brightness
"$HOME/Scripts/duo-usb-brightness.sh" 3

# write brightness level to state file
echo "3" > "$STATE"
