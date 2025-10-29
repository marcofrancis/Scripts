#!/usr/bin/env bash
#
# Repair Bluetooth Touchpad/Keyboard Script
#
# This script automates the process of repairing a misbehaving Bluetooth device,
# specifically tailored for an ASUS Zenbook Duo keyboard/touchpad that may lose
# functionality. It performs a clean re-pairing process to restore the device's
# connection and services.
#
# The script has two modes of operation:
#   - Soft Repair (default): Removes the device from BlueZ's cache, untrusts it,
#     and then attempts to pair again without restarting the Bluetooth service.
#     This is less disruptive and often sufficient.
#   - Hard Repair (optional): A more aggressive approach that restarts the system's
#     Bluetooth service and manually deletes the device's cached configuration
#     from the filesystem before attempting to re-pair. This can resolve more
#     stubborn issues.
#
# Safety checks are included to prevent accidentally removing the wrong device.
#

# Stop on first error, undefined variable, or pipe failure
set -euo pipefail

# --- Configuration (can be overridden via environment variables) ---

# The exact Bluetooth MAC address of the device to repair.
MAC="${MAC:-FE:1A:DA:F8:02:AF}"

# The PIN/passkey to use if the pairing process prompts for one.
PIN="${PIN:-0000}"

# A string that must be present in the device's alias (name).
# This is a safety measure to avoid repairing the wrong device.
ALIAS_MATCH="${ALIAS_MATCH:-ASUS Zenbook Duo Keyboard}"

# If set to "1", the script will verify that the device advertises HID
# (Human Interface Device) services before proceeding.
ONLY_HID="${ONLY_HID:-1}"

# Set to "1" to enable the hard repair method if the soft repair fails.
# 0 = Soft repair only (default)
# 1 = Soft repair, then hard repair on failure
HARD="${HARD:-0}"

# Path to the log file for this script's operations.
LOG="${LOG:-$HOME/Scripts/repair-touchpad.log}"

# Set to "1" to enable verbose output to the console.
DEBUG="${DEBUG:-1}"

# --- Logging Functions ---

# ts: Returns the current timestamp for logging.
ts(){ date +"%Y-%m-%d %H:%M:%S%z"; }
# log: Prints a message to the console (if DEBUG=1) and appends to the log file.
log(){
    printf "[%s] %s\n" "$(ts)" "$*" | tee -a "$LOG" >/dev/null
    [[ "$DEBUG" == "1" ]] && echo "$*"
}
# run: Executes a command, logging it first, and redirecting its output to the log file.
run(){
    log ">> $*"
    bash -lc "$*" >>"$LOG" 2>&1
}

# --- Initialization ---

# Clear the log file at the start of the script.
: >"$LOG"
log "=== START RE-PAIR (soft=${HARD} hard=${HARD}) ==="
log "MAC=$MAC PIN=$PIN ALIAS_MATCH='$ALIAS_MATCH' ONLY_HID=$ONLY_HID DEBUG=$DEBUG"

# Check for the required 'bluetoothctl' utility.
command -v bluetoothctl >/dev/null || { echo "bluetoothctl not found"; exit 1; }

# --- Pre-flight Checks ---

# Ensure the Bluetooth adapter is powered on.
log "Ensuring Bluetooth adapter is powered on…"
run "rfkill unblock bluetooth || true"
run "bluetoothctl power on || true"

# Fetch information about the device from bluetoothctl's cache.
log "Fetching device info for $MAC…"
INFO="$(bluetoothctl info "$MAC" 2>/dev/null || true)"
if [[ -z "$INFO" ]]; then
  log "NOTE: Device not in controller cache yet. That’s fine; continuing."
else
  # If the device is found, perform safety checks.
  log "Device found in cache. Performing safety checks…"

  # Safety Check 1: Verify the device alias matches the expected string.
  if [[ -n "$ALIAS_MATCH" ]]; then
    ALIAS="$(printf "%s" "$INFO" | awk -F': ' '/Alias:/ {print substr($0, index($0,$2))}')"
    log "Verifying alias: '$ALIAS' must contain '$ALIAS_MATCH'"
    if [[ "$ALIAS" != *"$ALIAS_MATCH"* ]]; then
      log "ABORT: Alias '$ALIAS' does not contain '$ALIAS_MATCH'."
      exit 20
    fi
  fi

  # Safety Check 2: Verify the device is a Human Interface Device if requested.
  if [[ "$ONLY_HID" == "1" ]]; then
    log "Verifying device is a Human Interface Device (HID)..."
    # Check for standard HID or HOGP (HID over GATT Profile) UUIDs.
    if ! (printf "%s" "$INFO" | grep -qiE 'UUID:.*(Human-Interface|00001124-0000-1000-8000-00805f9b34fb|00001812-0000-1000-8000-00805f9b34fb)'); then
      log "ABORT: Device does not advertise HID/HOGP UUIDs (1124/1812)."
      exit 21
    fi
  fi
fi

# Set up a non-interactive pairing agent to handle pairing automatically.
log "Registering non-interactive agent to avoid prompts…"
run "bluetoothctl agent off || true"
run "bluetoothctl agent NoInputNoOutput"
# run "bluetoothctl default-agent" # This is often implicitly set.

# --- Repair Functions ---

# soft_repair: Attempts to re-pair without restarting the Bluetooth service.
soft_repair() {
  log "--- Starting SOFT re-pair ---"
  log "Untrusting and removing device..."
  run "bluetoothctl untrust $MAC || true"
  run "bluetoothctl remove  $MAC || true"

  # Enable pairing on the host adapter.
  log "Enabling pairable mode..."
  run "bluetoothctl pairable on || true"

  # Scan for a few seconds to help the adapter discover the device.
  log "Scanning for 5s to ensure device is advertising..."
  set +e # Don't exit if timeout fails
  timeout 5s bluetoothctl scan on >>"$LOG" 2>&1
  set -e
  log "Scan finished."

  # Attempt to pair with the device.
  log "Attempting to pair with $MAC..."
  set +e # Don't exit on pairing failure
  bluetoothctl pair "$MAC" >>"$LOG" 2>&1
  rc=$?
  set -e
  log "pair() exit code: $rc"
  return $rc
}

# hard_repair: Performs a more forceful repair by restarting services.
hard_repair() {
  log "--- Starting HARD re-pair ---"

  # Find the host Bluetooth adapter's MAC address.
  log "Finding Bluetooth adapter MAC address..."
  ADAPTER="$(bluetoothctl list | awk '{print $2; exit}')"
  if [[ -z "$ADAPTER" ]]; then
    run "bluetoothctl power on || true"
    ADAPTER="$(bluetoothctl list | awk '{print $2; exit}')"
  fi
  [[ -n "$ADAPTER" ]] || { log "ABORT: No adapter found"; return 2; }
  log "Adapter found: $ADAPTER"

  # Restart the Bluetooth service. This clears a lot of state.
  log "Restarting Bluetooth service..."
  run "sudo systemctl restart bluetooth"
  run "bluetoothctl power on || true"

  # Manually delete the device's cached configuration file.
  log "Wiping cached device record for $MAC..."
  run "sudo rm -rf '/var/lib/bluetooth/$ADAPTER/$MAC' || true"

  # Re-register the pairing agent after the service restart.
  log "Re-registering non-interactive agent..."
  run "bluetoothctl agent off || true"
  run "bluetoothctl agent NoInputNoOutput"
  run "bluetoothctl default-agent"
  run "bluetoothctl pairable on || true"

  # Scan again to discover the device.
  log "Scanning for 5s to ensure device is advertising..."
  set +e
  timeout 5s bluetoothctl scan on >>"$LOG" 2>&1
  set -e
  log "Scan finished."

  # Attempt to pair again.
  log "Attempting to pair with $MAC (hard)..."
  set +e
  bluetoothctl pair "$MAC" >>"$LOG" 2>&1
  rc=$?
  set -e
  log "pair(hard) exit code: $rc"
  return $rc
}

# --- Main Execution Flow ---

# Start with a soft repair attempt.
PAIR_SUCCESS=0
log "Attempting soft re-pair first..."
if soft_repair; then
  PAIR_SUCCESS=1
  log "Soft re-pair SUCCEEDED."
else
  log "Soft re-pair FAILED."
fi

# If soft repair failed and hard repair is enabled, escalate.
if [[ $PAIR_SUCCESS -ne 1 && "$HARD" == "1" ]]; then
  log "Soft re-pair failed; escalating to HARD…"
  if hard_repair; then
    PAIR_SUCCESS=1
    log "Hard re-pair SUCCEEDED."
  else
    log "HARD re-pair failed. Device likely needs to be in pairing mode."
    echo "Pair failed. Put the keyboard/touchpad in pairing mode, then re-run:"
    echo "  DEBUG=1 HARD=1 MAC=$MAC ~/Scripts/repair-touchpad.sh"
    exit 10
  fi
fi

# If all attempts failed, exit with an error.
if [[ $PAIR_SUCCESS -ne 1 ]]; then
  log "All pairing attempts failed. Please ensure device is in pairing mode and try again."
  echo "Re-pair failed. Put the keyboard/touchpad in pairing mode, then re-run."
  exit 1
fi

# After a successful pairing, trust the device and attempt to connect.
log "Pairing complete. Trusting and connecting..."
run "bluetoothctl trust $MAC"
set +e
bluetoothctl connect "$MAC" >>"$LOG" 2>&1
CONN_RC=$?
set -e
log "connect() exit code: $CONN_RC"

# --- Finalization ---

# Log the final status of the device.
log "Fetching final device status..."
run "bluetoothctl info $MAC || true"
log "=== END RE-PAIR ==="

# Provide a summary message to the user.
if [[ $CONN_RC -eq 0 ]]; then
  echo "Re-pair OK → Connected to $MAC."
else
  echo "Re-pair OK → Paired but connect failed. Try: bluetoothctl connect $MAC"
fi

# Optional: Hint for refreshing KDE's Bluetooth applet if it's out of sync.
# (safe to run; does NOT toggle the adapter)
#   qdbus org.kde.kded5 /kded unloadModule bluedevil; qdbus org.kde.kded5 /kded loadModule bluedevil
