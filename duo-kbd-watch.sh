#!/usr/bin/env bash
#
# ASUS Zenbook Duo Keyboard Watcher
#
# This script continuously monitors the connection status of the ASUS Zenbook Duo
# keyboard. It automatically manages the second screen and keyboard backlight
# brightness when the keyboard is docked (attached via USB) or undocked (detached).
#
# Features:
#   - Detects keyboard attachment/detachment by monitoring USB events.
#   - When the keyboard is attached (docked):
#     - The bottom screen is automatically disabled.
#     - The keyboard's USB backlight is set to the last known brightness level.
#   - When the keyboard is detached (undocked):
#     - The bottom screen is automatically enabled.
#     - The keyboard's Bluetooth backlight is set to the last known brightness level.
#   - Brightness level is persisted in a state file.
#   - Supports both KDE (kscreen-doctor) and GNOME (gnome-monitor-config) for
#     display management.
#
# This script is intended to be run as a background service.
#

# Stop on first error, undefined variable, or pipe failure
set -euo pipefail

# --- Configuration ---

# USB Vendor ID for ASUS.
ASUS_VENDOR="${ASUS_VENDOR:-0b05}"

# Comma-separated list of USB Product IDs for the Duo keyboard.
# This allows for different revisions of the hardware.
DUO_KB_USB_IDS="${DUO_KB_USB_IDS:-1bf2,1b2c}"

# Display output names. These may need to be adjusted based on your system's
# display configuration (check 'xrandr' or 'kscreen-doctor -o').
TOP_OUT="${TOP_OUT:-eDP-1}"
BOT_OUT="${BOT_OUT:-eDP-2}"

# Path to the file that stores the current keyboard brightness level (0-3).
STATE="$HOME/Scripts/kb-level.state"

# --- Helper Functions ---

# have: Checks if a command exists in the system's PATH.
# Usage: have kscreen-doctor
have() { command -v "$1" >/dev/null 2>&1; }

# get_brightness_level: Reads the brightness level from the state file.
# If the file doesn't exist or contains an invalid value, it initializes it to "0".
get_brightness_level() {
  # ensure state file exists and is sane
  if [[ ! -f "$STATE" ]] || ! grep -qE '^[0-3]$' "$STATE"; then
    echo "0" > "$STATE"
  fi
  cat "$STATE"
}

# --- Display Management Functions ---

# display_disable_bottom: Disables the bottom display output.
# It uses the appropriate tool for KDE (kscreen-doctor) or GNOME.
display_disable_bottom() {
  if have kscreen-doctor; then
    kscreen-doctor "output.${BOT_OUT}.disable" >/dev/null
  elif have gnome-monitor-config; then
    gnome-monitor-config set --off "${BOT_OUT}" >/dev/null
  else
    echo "[duo] No supported display tool (kscreen-doctor|gnome-monitor-config) found." >&2
  fi
}

# display_enable_bottom: Enables the bottom display output.
# It places the bottom screen below the top screen.
display_enable_bottom() {
  if have kscreen-doctor; then
    kscreen-doctor "output.${BOT_OUT}.enable" >/dev/null
  elif have gnome-monitor-config; then
    # The '|| true' prevents the script from exiting if the command fails,
    # which can sometimes happen during rapid transitions.
    gnome-monitor-config set --on "${BOT_OUT}" --below "${TOP_OUT}" >/dev/null || true
  else
    echo "[duo] No supported display tool (kscreen-doctor|gnome-monitor-config) found." >&2
  fi
}

# --- Keyboard Detection Functions ---

# is_keyboard_docked_sysfs: Checks if the keyboard is docked by scanning sysfs.
# This is the preferred method as it's fast and doesn't rely on external commands.
# It iterates through USB devices and checks their Vendor and Product IDs.
is_keyboard_docked_sysfs() {
  for d in /sys/bus/usb/devices/*; do
    # Skip directories that are not USB devices.
    [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
    v=$(<"$d/idVendor")
    p=$(<"$d/idProduct")
    # Check if the vendor is ASUS.
    [[ "$v" == "$ASUS_VENDOR" ]] || continue
    # Check if the product ID is in our list of known keyboard IDs.
    for pid in ${DUO_KB_USB_IDS//,/ }; do
      if [[ "$p" == "$pid" ]]; then return 0; fi # Found
    done
  done
  return 1 # Not found
}

# is_keyboard_docked_lsusb: A fallback method to check for the keyboard using 'lsusb'.
# This is slower than the sysfs method.
is_keyboard_docked_lsusb() {
  for pid in ${DUO_KB_USB_IDS//,/ }; do
    if lsusb -d "${ASUS_VENDOR}:${pid}" >/dev/null 2>&1; then
      return 0 # Found
    fi
  done
  return 1 # Not found
}

# is_keyboard_docked: The main detection function.
# It tries the fast sysfs method first, then falls back to lsusb if necessary.
is_keyboard_docked() {
  is_keyboard_docked_sysfs || is_keyboard_docked_lsusb
}

# --- Main Logic ---

# apply_state: Takes action based on the current keyboard state ("attached" or "detached").
apply_state() {
  local state="$1"
  if [[ "$state" == "attached" ]]; then
    echo "[duo] Keyboard ATTACHED -> disabling bottom screen (${BOT_OUT})"
    display_disable_bottom
    local level
    level="$(get_brightness_level)"
    echo "[duo] Setting USB keyboard brightness to level ${level}..."
    # Call the script to set brightness over USB.
    "$HOME/Scripts/duo-usb-brightness.sh" "${level}" &>/dev/null || true
  else # detached
    echo "[duo] Keyboard DETACHED -> enabling bottom screen (${BOT_OUT})"
    display_enable_bottom
    echo "[duo] Waiting 2 seconds before setting Bluetooth brightness..."
    # A short delay can help ensure the Bluetooth connection is stable after detachment.
    sleep 2
    local level
    level="$(get_brightness_level)"
    echo "[duo] Setting Bluetooth keyboard brightness to level ${level}..."
    # Call the script to set brightness over Bluetooth.
    "$HOME/Scripts/duo-bt-brightness.sh" "${level}" &>/dev/null || true
  fi
}

# debounced_check_and_apply: Checks the keyboard state and only acts if it has changed.
# This prevents running the 'apply_state' logic multiple times for a single event.
debounced_check_and_apply() {
  local cur
  if is_keyboard_docked; then cur="attached"; else cur="detached"; fi

  # Compare the current state with the last known state.
  if [[ "${cur}" != "${LAST_STATE:-}" ]]; then
    # If the state changed, update the last known state and apply the new state.
    LAST_STATE="$cur"
    apply_state "$cur"
  fi
}

# main: The main function of the script.
main() {
  # Perform an initial check on startup.
  debounced_check_and_apply

  # Monitor udev for USB events.
  # The 'while read' loop will block until a new event occurs.
  echo "[duo] Watching for USB events..."
  udevadm monitor --udev --subsystem-match=usb | while read -r _; do
    # Wait a moment for the device to settle after an event.
    sleep 0.5
    debounced_check_and_apply
  done
}

# --- Script Entry Point ---
main
