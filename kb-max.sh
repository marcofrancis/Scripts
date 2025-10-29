#!/usr/bin/env bash
#
# Set Keyboard Brightness to Maximum (USB)
#
# This script sets the brightness of the ASUS Zenbook Duo keyboard to its
# maximum level (3) when connected via USB. It also updates the shared
# state file to reflect this change.
#
# This is useful for scenarios where you want to ensure the keyboard is fully
# lit, such as when waking the computer from sleep or manually activating it.
#
# A lock file is used to prevent concurrent modifications to the state file.
#

# Stop on first error, undefined variable, or pipe failure
set -euo pipefail

# --- Configuration ---

# Path to the file that stores the current keyboard brightness level (0-3).
STATE="$HOME/Scripts/kb-level.state"

# Path to the lock file to prevent concurrent execution.
LOCK="$STATE.lock"

# --- Script Logic ---

# Use a lock file to ensure that only one instance of this script runs at a time,
# preventing race conditions when accessing the state file.
# The lock is automatically released when the script exits.
exec 9>"$LOCK"
flock -x 9

# Ensure the state file exists and contains a valid value (0-3).
# If not, initialize it to "0". This is good practice, although this script
# will overwrite it anyway.
if [[ ! -f "$STATE" ]] || ! grep -qE '^[0-3]$' "$STATE"; then
  echo "0" > "$STATE"
fi

echo "Setting keyboard brightness to maximum (3)..."

# Call the main USB brightness script with the maximum level.
"$HOME/Scripts/duo-usb-brightness.sh" 3

# Update the state file to record that the brightness is now at level 3.
echo "3" > "$STATE"

echo "Done."
