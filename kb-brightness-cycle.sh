#!/usr/bin/env bash
#
# Keyboard Brightness Cycle Script (Unified USB + Bluetooth)
#
# This script toggles the ASUS Zenbook Duo keyboard brightness between
# off (0) and maximum (3). It simultaneously targets both the USB and
# Bluetooth keyboards, relying on each underlying brightness helper script
# to exit gracefully if the respective device is not connected.
#
# How it works:
#   1. It reads the last known brightness level from a shared state file.
#   2. If the current level is 0 (off), it sets the brightness to 3 (max).
#   3. Otherwise, it sets the brightness to 0 (off).
#   4. The new level is written back to the state file.
#
# A lock file prevents race conditions when the script is triggered in quick
# succession (for example, from rapid key presses).

# Stop on first error, undefined variable, or pipe failure
set -euo pipefail

# --- Configuration ---

# Path to the file that stores the current keyboard brightness level (0-3).
# This state is shared by the USB and Bluetooth cycle scripts.
STATE="$HOME/Scripts/kb-level.state"

# Path to the lock file to prevent concurrent execution.
LOCK="$STATE.lock"

# Paths to the helper scripts that control USB and Bluetooth keyboard brightness.
USB_SCRIPT="$HOME/Scripts/duo-usb-brightness.sh"
BT_SCRIPT="$HOME/Scripts/duo-bt-brightness.sh"

# Timeout (in seconds) for the Bluetooth brightness helper. If the command hangs,
# we abort after this duration and continue without failing the script.
BT_TIMEOUT=1

# --- Script Logic ---

# Ensure only one instance runs at a time to protect the shared state file.
exec 9>"$LOCK"
flock -x 9

# Ensure the state file exists and contains a valid value (0-3).
if [[ ! -f "$STATE" ]] || ! grep -qE '^[0-3]$' "$STATE"; then
  echo "0" > "$STATE"
fi

# Read the current brightness level from the state file.
level="$(cat "$STATE")"

# Determine the next brightness level.
if [[ "$level" -eq 0 ]]; then
  next=3
else
  next=0
fi

# Call both brightness scripts. Each call is allowed to fail silently in case
# the associated device is not connected.
"$USB_SCRIPT" "$next" || true

if command -v timeout >/dev/null 2>&1; then
  if timeout "$BT_TIMEOUT" "$BT_SCRIPT" "$next"; then
    :
  else
    bt_status=$?
    if [[ "$bt_status" -eq 124 ]]; then
      echo "Warning: Bluetooth brightness script timed out after ${BT_TIMEOUT}s; continuing." >&2
    fi
  fi
else
  "$BT_SCRIPT" "$next" || true
fi

# Persist the new level for the next run.
echo "$next" > "$STATE"

# Provide user feedback.
if [[ "$next" -eq 0 ]]; then
  echo "Set brightness to off."
else
  echo "Set brightness to max."
fi


