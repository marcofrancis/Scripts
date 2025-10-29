#!/usr/bin/env bash
#
# Set the keyboard brightness level for the ASUS Zenbook Duo Bluetooth keyboard.
#
# This script sends a special GATT command over Bluetooth to control the
# keyboard's backlight brightness. It requires 'bluetoothctl' to be installed
# and the keyboard to be paired with the system.
#
# The script can automatically discover the keyboard's MAC address if not
# provided, connects to it, and sends the brightness command.
#

# Stop on first error, undefined variable, or pipe failure
set -euo pipefail

# --- Configuration ---
# These variables can be overridden by setting them in the environment before
# running the script. For example:
#   KB_NAME="My Custom Keyboard" ./duo-bt-brightness.sh 2

# The name of the keyboard as it appears in 'bluetoothctl devices'
: "${KB_NAME:=ASUS Zenbook Duo Keyboard}"

# The Bluetooth MAC address of the keyboard. If empty, the script will try to find it.
: "${KB_MAC:=}"

# The GATT attribute path for the brightness control. This is specific to the
# keyboard model and unlikely to need changing.
: "${KB_ATTR:=service001b/char003b}"


# --- Script Logic ---

# Read the brightness level from the first command-line argument.
LEVEL="${1:-}"
# Validate that the level is a number between 0 and 3.
if [[ -z "${LEVEL}" || ! "${LEVEL}" =~ ^[0-3]$ ]]; then
  echo "Usage: $0 <0|1|2|3>"
  echo "  Sets the keyboard brightness level."
  exit 2
fi

# If the MAC address is not provided, try to find it using bluetoothctl.
if [[ -z "${KB_MAC:-}" ]]; then
  # Search for the keyboard by its name and store matching lines in an array.
  # The '|| true' prevents the script from exiting if grep finds no matches.
  mapfile -t lines < <(bluetoothctl devices | grep -i "${KB_NAME}" || true)

  # If no devices with that name are found, print an error and exit.
  if (( ${#lines[@]} == 0 )); then
    echo "Error: Keyboard '${KB_NAME}' not found in 'bluetoothctl devices'." >&2
    echo "Please make sure the keyboard is paired and discoverable." >&2
    exit 1
  fi

  # Extract the MAC address from the first line of the output.
  # The output format is "Device XX:XX:XX:XX:XX:XX Device Name".
  KB_MAC="$(echo "${lines[0]}" | awk '{print $2}')"
  echo "Info: Found keyboard MAC address: ${KB_MAC}" >&2
fi

# Attempt to connect to the keyboard. This is a no-op if already connected.
# We also trust the device to prevent future pairing prompts.
# Output is redirected to /dev/null to keep the script quiet on success.
# '|| true' prevents exit on connection/trust failure (e.g., device busy).
echo "Info: Connecting and trusting device..." >&2
bluetoothctl connect "${KB_MAC}" >/dev/null 2>&1 || true
bluetoothctl trust "${KB_MAC}" >/dev/null 2>&1 || true

# Convert the MAC address to the format used by BlueZ in D-Bus object paths.
# This means replacing colons (:) with underscores (_).
BLUEZ_MAC_PATH="$(echo "${KB_MAC}" | tr ':' '_')"

# Construct the full D-Bus path to the GATT characteristic.
# hci0 is the default Bluetooth adapter, which is usually correct.
ATTR_PATH="/org/bluez/hci0/dev_${BLUEZ_MAC_PATH}/${KB_ATTR}"

# The brightness command is a sequence of four bytes: BA, C5, C4, followed by the level.
# We map the numeric level (0-3) to its hexadecimal representation (0x00-0x03).
case "${LEVEL}" in
  0) HEX_LEVEL="0x00" ;; # Off
  1) HEX_LEVEL="0x01" ;; # Low
  2) HEX_LEVEL="0x02" ;; # Medium
  3) HEX_LEVEL="0x03" ;; # High
esac

# Use a 'here document' to send a series of commands to bluetoothctl.
# This is a non-interactive way to script bluetoothctl actions.
# The output is redirected to /dev/null to hide command confirmations.
echo "Info: Setting brightness to level ${LEVEL}..." >&2
bluetoothctl &>/dev/null <<EOF
# Select the GATT attribute (characteristic) we want to write to.
gatt.select-attribute ${ATTR_PATH}
# Write the four-byte command as a hexadecimal string.
gatt.write "0xba 0xc5 0xc4 ${HEX_LEVEL}"
# The connection will be automatically closed by bluetoothctl.
EOF

echo "Info: Brightness set successfully." >&2
