#!/usr/bin/env bash
set -euo pipefail

# --- IDs from your lsusb ---
ASUS_VENDOR="${ASUS_VENDOR:-0b05}"
# Include 1bf2 (yours) and keep 1b2c as a fallback just in case
DUO_KB_USB_IDS="${DUO_KB_USB_IDS:-1bf2,1b2c}"

# Outputs (override via env if needed)
TOP_OUT="${TOP_OUT:-eDP-1}"
BOT_OUT="${BOT_OUT:-eDP-2}"

have() { command -v "$1" >/dev/null 2>&1; }

display_disable_bottom() {
  if have kscreen-doctor; then
    kscreen-doctor "output.${BOT_OUT}.disable" >/dev/null
  elif have gnome-monitor-config; then
    gnome-monitor-config set --off "${BOT_OUT}" >/dev/null
  else
    echo "[duo] No supported display tool (kscreen-doctor|gnome-monitor-config) found."
  fi
}

display_enable_bottom() {
  if have kscreen-doctor; then
    kscreen-doctor "output.${BOT_OUT}.enable" >/dev/null
  elif have gnome-monitor-config; then
    gnome-monitor-config set --on "${BOT_OUT}" --below "${TOP_OUT}" >/dev/null || true
  else
    echo "[duo] No supported display tool (kscreen-doctor|gnome-monitor-config) found."
  fi
}

# Fast & reliable: check sysfs for vendor/product pairs
is_keyboard_docked_sysfs() {
  for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
    v=$(<"$d/idVendor")
    p=$(<"$d/idProduct")
    [[ "$v" == "$ASUS_VENDOR" ]] || continue
    for pid in ${DUO_KB_USB_IDS//,/ }; do
      if [[ "$p" == "$pid" ]]; then return 0; fi
    done
  done
  return 1
}

# Fallback to lsusb if needed
is_keyboard_docked_lsusb() {
  for pid in ${DUO_KB_USB_IDS//,/ }; do
    if lsusb -d "${ASUS_VENDOR}:${pid}" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

is_keyboard_docked() {
  is_keyboard_docked_sysfs || is_keyboard_docked_lsusb
}

apply_state() {
  local state="$1"
  if [[ "$state" == "attached" ]]; then
    echo "[duo] Keyboard ATTACHED -> disabling bottom screen (${BOT_OUT})"
    display_disable_bottom
  else
    echo "[duo] Keyboard DETACHED -> enabling bottom screen (${BOT_OUT})"
    display_enable_bottom
  fi
}

debounced_check_and_apply() {
  local cur
  if is_keyboard_docked; then cur="attached"; else cur="detached"; fi
  if [[ "${cur}" != "${LAST_STATE:-}" ]]; then
    LAST_STATE="$cur"
    apply_state "$cur"
  fi
}

main() {
  debounced_check_and_apply
  # Watch USB events and re-check presence
  udevadm monitor --udev --subsystem-match=usb | while read -r _; do
    sleep 0.5
    debounced_check_and_apply
  done
}

main
