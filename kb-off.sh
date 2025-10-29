#!/usr/bin/env bash
#
# Turn Off Keyboard Brightness (USB)
#
# This script turns off the backlight of the ASUS Zenbook Duo keyboard when it
# is connected via USB. It sets the brightness level to 0 and updates the
# shared state file to reflect this change.
#
# This is useful for explicitly turning off the keyboard light, for example,
# before the system goes to sleep or when the screen is locked.
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
# If not, initialize it to "0".
if [[ ! -f "$STATE" ]] || ! grep -qE '^[0-3]$' "$STATE"; then
  echo "0" > "$STATE"
fi

echo "Turning keyboard brightness off..."

# Call the main USB brightness script with level 0.
"$HOME/Scripts/duo-usb-brightness.sh" 0

# Update the state file to record that the brightness is now at level 0.
echo "0" > "$STATE"

echo "Done."
