#!/usr/bin/env bash
#
# Keyboard Brightness Cycle Script (Bluetooth)
#
# This script cycles the brightness of the ASUS Zenbook Duo Bluetooth keyboard
# between off (0) and maximum (3). It's designed to be a simple toggle.
#
# How it works:
#   1. It reads the last known brightness level from a state file.
#   2. If the current level is 0 (off), it sets the brightness to 3 (max).
#   3. If the current level is anything other than 0, it sets the brightness to 0 (off).
#   4. The new level is saved back to the state file for the next run.
#
# This script uses a lock file to prevent race conditions if it's called
# multiple times in quick succession.
#

# Stop on first error, undefined variable, or pipe failure
set -euo pipefail

# --- Configuration ---

# Path to the file that stores the current keyboard brightness level (0-3).
STATE="$HOME/Scripts/kb-level.state"

# Path to the lock file to prevent concurrent execution.
LOCK="$STATE.lock"

# Path to the main script that controls the Bluetooth keyboard brightness.
MAIN="$HOME/Scripts/duo-bt-brightness.sh"

# --- Script Logic ---

# Use a lock file to ensure that only one instance of this script runs at a time.
# This prevents the state file from becoming corrupted if the script is
# triggered rapidly (e.g., by multiple key presses).
# The lock is automatically released when the script exits.
exec 9>"$LOCK"
flock -x 9

# Ensure the state file exists and contains a valid value (0-3).
# If not, initialize it to "0".
if [[ ! -f "$STATE" ]] || ! grep -qE '^[0-3]$' "$STATE"; then
  echo "0" > "$STATE"
fi

# Read the current brightness level from the state file.
level="$(cat "$STATE")"

# Determine the next brightness level.
# If the keyboard is currently off, turn it to maximum brightness.
# Otherwise, turn it off.
if [[ "$level" -eq 0 ]]; then
  next=3
else
  next=0
fi

echo "[kb-cycle] Current level: $level, next level: $next"

# Call the main brightness script to set the new level.
# '|| true' prevents the script from exiting if the brightness command fails
# (e.g., if the keyboard is not connected).
"$MAIN" "$next" || true

# Save the new level to the state file for the next run.
echo "$next" > "$STATE"
