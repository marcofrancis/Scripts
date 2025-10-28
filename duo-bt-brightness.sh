#!/usr/bin/env bash
set -euo pipefail

# Usage: duo-bt-brightness.sh <0|1|2|3>
# Env overrides (optional):
#   KB_NAME="ASUS Zenbook Duo Keyboard"
#   KB_MAC="AA:BB:CC:DD:EE:FF"
#   KB_ATTR="service001b/char003b"

LEVEL="${1:-}"
if [[ -z "${LEVEL}" || ! "${LEVEL}" =~ ^[0-3]$ ]]; then
  echo "Usage: $0 <0|1|2|3>"; exit 2
fi

KB_NAME="${KB_NAME:-ASUS Zenbook Duo Keyboard}"
KB_ATTR="${KB_ATTR:-service001b/char003b}"

# Resolve MAC if not provided
if [[ -z "${KB_MAC:-}" ]]; then
  # Pick the first match; adjust the grep if your Bluetooth name differs slightly.
  mapfile -t lines < <(bluetoothctl devices | grep -i "${KB_NAME}" || true)
  if (( ${#lines[@]} == 0 )); then
    echo "Keyboard '${KB_NAME}' not found in 'bluetoothctl devices'. Is it paired?"; exit 1
  fi
  KB_MAC="$(echo "${lines[0]}" | awk '{print $2}')"
fi

# Ensure connected (no-op if already connected)
bluetoothctl connect "${KB_MAC}" >/dev/null 2>&1 || true
# Trust the device (once)
bluetoothctl trust "${KB_MAC}" >/dev/null 2>&1 || true

# Convert MAC to BlueZ object path (XX:YY becomes XX_YY)
BLUEZ_MAC_PATH="$(echo "${KB_MAC}" | tr ':' '_')"
ATTR_PATH="/org/bluez/hci0/dev_${BLUEZ_MAC_PATH}/${KB_ATTR}"

# Compose magic bytes: BA C5 C4 <LEVEL>
# LEVEL is 0..3 mapped to 0x00..0x03
case "${LEVEL}" in
  0) HEX_LEVEL="0x00" ;;
  1) HEX_LEVEL="0x01" ;;
  2) HEX_LEVEL="0x02" ;;
  3) HEX_LEVEL="0x03" ;;
esac

# Write via bluetoothctl GATT commands
# We select the characteristic, then write the 4 bytes in hex form.
bluetoothctl &>/dev/null <<EOF
gatt.select-attribute ${ATTR_PATH}
gatt.write "0xba 0xc5 0xc4 ${HEX_LEVEL}"
EOF
