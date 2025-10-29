#!/usr/bin/env bash
#
# ASUS Zenbook Duo Detachable Keyboard Bluetooth Tracer
#
# This script is a comprehensive diagnostic tool for troubleshooting Bluetooth
# connectivity and input issues with the ASUS Zenbook Duo detachable keyboard.
# It captures a wide range of system information in near real-time, providing
# a holistic view of the Bluetooth stack, from the kernel up to the user session.
#
# It simultaneously monitors:
#   - BlueZ D-Bus messages for device property changes (connect, disconnect, etc.)
#   - Raw Bluetooth HCI traffic using 'btmon'
#   - Kernel messages related to Bluetooth, HID, and USB
#   - Udev events for the keyboard's input devices
#   - Libinput events for detailed touchpad/mouse gesture data (optional)
#   - Periodic snapshots of Bluetooth device properties, input device details,
#     and power management settings.
#
# All logs are saved to a timestamped directory in /tmp, making it easy to
# archive and share for remote debugging.
#
# Usage:
#   1. Run the script: ./duo-bt-trace.sh
#   2. The script will try to auto-detect the keyboard's MAC address.
#   3. Perform actions that trigger the issue (e.g., connect/disconnect,
#      use the touchpad, let the device sleep).
#   4. Press Ctrl+C to stop the script.
#   5. A .tgz archive of the logs will be suggested for easy sharing.
#

# --- Script Setup ---

# Exit immediately if a command exits with a non-zero status.
# Exit immediately if a pipeline exits with a non-zero status.
# Treat unset variables as an error when substituting.
# Inherit traps for shell functions.
set -Eeuo pipefail

# --- Configuration (from Environment Variables) ---

# The name of the keyboard as it appears in 'bluetoothctl devices'.
# Default: "ASUS Zenbook Duo Keyboard"
NAME="${DUO_KB_NAME:-ASUS Zenbook Duo Keyboard}"

# The Bluetooth MAC address. If empty, the script will auto-detect it.
# Default: ""
MAC="${DUO_KB_MAC:-}"

# The directory where logs will be saved.
# Default: /tmp/duo_bt_trace_YYYY-MM-DD_HH-MM-SS
OUTDIR="${DUO_TRACE_DIR:-/tmp/duo_bt_trace_$(date +%F_%H-%M-%S)}"

# The interval in milliseconds for taking periodic snapshots.
# Default: 2000 (2 seconds)
POLL_MS="${DUO_POLL_MS:-2000}"

# Set to "1" to reduce console output. All logs are still written to files.
# Default: "0"
QUIET="${DUO_QUIET:-0}"

# Set to "1" to enable capturing 'libinput debug-events'.
# This may require running the script with sudo.
# Default: "0"
LIBINPUT_STREAM="${DUO_LIBINPUT:-0}"

# --- Initialization ---

# Create the output directory.
mkdir -p "$OUTDIR"
# Define the main log file path.
LOG="$OUTDIR/trace.log"
# Create the log file if it doesn't exist.
touch "$LOG" >/dev/null 2>&1 || true

# --- Logging Functions ---

# log: Prints a timestamped message to both the console and the main log file.
log(){ printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG"; }
# vlog: "Verbose log". Prints only to the file if QUIET=1, otherwise behaves like log().
vlog(){ [ "$QUIET" = "1" ] && printf '%s\n' "$*" >>"$LOG" || log "$*"; }
# banner: Prints a formatted section header.
banner(){ printf '\n=== %s ===\n' "$1" | tee -a "$LOG"; }
# die: Prints an error message and exits the script.
die(){ log "ERROR: $*"; exit 1; }

# --- Helper Functions ---

# detect_mac: Finds the MAC address of the keyboard using 'bluetoothctl'.
# If a MAC is already set in the environment, this function does nothing.
# If no device is found, the script exits with an error.
detect_mac() {
  if [[ -n "$MAC" ]]; then return 0; fi
  # Find device by name, print the MAC (2nd column), and exit awk.
  MAC="$(bluetoothctl devices 2>/dev/null | awk -v pat="$NAME" '$0 ~ pat {print $2; exit}')"
  [[ -n "$MAC" ]] || die "Could not find MAC for '$NAME'. Pair it, or set DUO_KB_MAC=AA:BB:CC:DD:EE:FF"
}

# dev_obj_path: Converts the MAC address to a BlueZ D-Bus object path.
# Example: FE:1A:DA:F8:02:AF -> /org/bluez/hci0/dev_FE_1A_DA_F8_02_AF
dev_obj_path() {
  printf '/org/bluez/hci0/dev_%s\n' "$(echo "$MAC" | tr ':' '_')"
}

# hci_parent_path: Finds the sysfs path of the parent device for the hci0 adapter.
# This is useful for inspecting power management settings of the USB dongle.
hci_parent_path() {
  local p; p="$(readlink -f /sys/class/bluetooth/hci0/device || true)"
  [[ -n "$p" ]] && printf '%s\n' "$p"
}

# event_nodes: Identifies the /dev/input/event* nodes for the keyboard's
# Mouse and Touchpad components by parsing /proc/bus/input/devices.
event_nodes() {
  # This awk script finds lines with the device name, then extracts all "event[0-9]+"
  # strings from the "Handlers" line that follows.
  awk '
    BEGIN{s=0}
    /^N: Name="ASUS Zenbook Duo Keyboard (Mouse|Touchpad)"/{s=1; next}
    s && /^H: Handlers=/{ while (match($0,/event[0-9]+/)) { print substr($0,RSTART,RLENGTH); $0=substr($0,RSTART+RLENGTH) } s=0 }
  ' /proc/bus/input/devices 2>/dev/null | sort -u
}

# --- Snapshot Functions ---
# These functions are called periodically to capture the state of various subsystems.

# snapshot_input_props: Records details about input devices.
# It saves a list of all input devices and detailed udev properties for the keyboard.
snapshot_input_props() {
  local f="$OUTDIR/snap-input.txt"
  {
    echo "--- $(date +%F\ %T) ---"
    # List all input devices, filtering for relevant names.
    grep -i -E 'Asus|ELAN|mouse|touchpad|keyboard' /proc/bus/input/devices 2>/dev/null || true
    # For each keyboard event node, dump its udev properties.
    for ev in $(event_nodes); do
      local dev="/dev/input/$ev"
      echo "### $dev udev props ###"
      udevadm info -q property -n "$dev" 2>/dev/null | grep -E 'NAME=|ID_INPUT|ID_BUS|ID_PATH|USEC_INITIALIZED' || true
    done
  } >> "$f"
}

# snapshot_bt_props: Records the state of the Bluetooth device.
# It captures 'bluetoothctl info' and specific D-Bus properties.
snapshot_bt_props() {
  local f="$OUTDIR/snap-bluez.txt" obj; obj="$(dev_obj_path)"
  {
    echo "--- $(date +%F\ %T) ---"
    # General device info from bluetoothctl.
    bluetoothctl info "$MAC" 2>/dev/null || true
    # Specific properties from the BlueZ D-Bus interface.
    echo "busctl Device1 props:"
    busctl get-property org.bluez "$obj" org.bluez.Device1 Connected       2>/dev/null || true
    busctl get-property org.bluez "$obj" org.bluez.Device1 ServicesResolved 2>/dev/null || true
    busctl get-property org.bluez "$obj" org.bluez.Device1 UUIDs           2>/dev/null || true
  } >> "$f"
}

# snapshot_power: Records power management settings for the Bluetooth adapter.
snapshot_power() {
  local f="$OUTDIR/snap-power.txt" h; h="$(hci_parent_path || true)"
  {
    echo "--- $(date +%F\ %T) ---"
    echo "hci0 parent: ${h:-unknown}"
    # Check the runtime power control status (e.g., 'on' or 'auto').
    if [[ -n "$h" && -e "$h/power/control" ]]; then
      printf 'hci parent power/control = %s\n' "$(cat "$h/power/control" 2>/dev/null || echo '?')"
    fi
    # List software and hardware radio kill switches.
    rfkill -o ID,TYPE,SOFT,HARD list 2>/dev/null || true
    # If the adapter is a USB device, check its autosuspend delay.
    if [[ -L "$h/../.." && -e "$h/../power/autosuspend_delay_ms" ]]; then
      printf 'autosuspend_delay_ms = %s\n' "$(cat "$h/../power/autosuspend_delay_ms" 2>/dev/null || echo '?')"
    fi
  } >> "$f"
}

# --- Background Data Collectors ---
# These functions start long-running processes to monitor system events.
# Their process IDs (PIDs) are stored in the 'pids' array for later cleanup.

pids=()

# start_btmon: Captures raw Bluetooth HCI (Host Controller Interface) traffic.
# This is useful for low-level debugging of the Bluetooth protocol.
start_btmon() {
  if command -v btmon >/dev/null 2>&1; then
    vlog "btmon → $OUTDIR/btmon.txt"
    # 'stdbuf -oL' ensures line-buffered output, so we see data as it arrives.
    stdbuf -oL btmon > "$OUTDIR/btmon.txt" 2>&1 & pids+=($!)
  else
    log "btmon not found; skipping HCI trace"
  fi
}

# start_dbusmon: Monitors D-Bus signals from BlueZ related to the keyboard.
# This captures high-level events like property changes (e.g., Connected: true/false).
start_dbusmon() {
  if command -v dbus-monitor >/dev/null 2>&1; then
    local obj; obj="$(dev_obj_path)"
    vlog "dbus-monitor BlueZ(Device1/**) → $OUTDIR/dbus.txt"
    dbus-monitor --system \
      "type='signal',sender='org.bluez',path='$obj'" \
      "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',path='$obj'" \
      > "$OUTDIR/dbus.txt" 2>&1 & pids+=($!)
  else
    log "dbus-monitor not found; skipping BlueZ DBus trace"
  fi
}

# start_udevmon: Monitors kernel and udev events for the 'input' subsystem.
# This shows when input devices are added, removed, or changed.
start_udevmon() {
  vlog "udevadm monitor(input) → $OUTDIR/udev.txt"
  udevadm monitor --kernel --udev --subsystem-match=input \
    | stdbuf -oL awk '{print strftime("[%F %T]"), $0}' \
    > "$OUTDIR/udev.txt" 2>&1 & pids+=($!)
}

# start_journalk: Tails the kernel log ('dmesg') for relevant messages.
# The output is filtered to show only lines related to Bluetooth, HID, USB, etc.
start_journalk() {
  vlog "journalctl -kf (filtered) → $OUTDIR/kernel.txt"
  journalctl -kf \
    | stdbuf -oL grep -E -i 'hid|asus|uhid|blue|bt|hci|rfkill|input|usb|multitouch' \
    > "$OUTDIR/kernel.txt" 2>&1 & pids+=($!)
}

# start_libinput_stream: Captures detailed input event data from libinput.
# This is disabled by default and can be enabled with DUO_LIBINPUT=1.
# It's useful for debugging touchpad gestures, pointer motion, etc.
start_libinput_stream() {
  [[ "$LIBINPUT_STREAM" = "1" ]] || { vlog "libinput stream disabled (set DUO_LIBINPUT=1 to enable)"; return; }
  if command -v libinput >/dev/null 2>&1; then
    vlog "libinput debug-events (filtered) → $OUTDIR/libinput.txt"
    # Note: may need sudo for full device access.
    libinput debug-events 2>&1 \
      | stdbuf -oL grep -E -i 'ASUS Zenbook Duo Keyboard|POINTER|GESTURE|SWITCH' \
      > "$OUTDIR/libinput.txt" & pids+=($!)
  else
    log "libinput not found; skipping"
  fi
}

# sampler: A loop that periodically calls the snapshot functions.
sampler() {
  local i=0
  while :; do
    ((i++)) || true
    snapshot_input_props
    snapshot_bt_props
    snapshot_power
    # Sleep for the configured poll interval.
    sleep "$(awk "BEGIN{printf \"%.3f\", $POLL_MS/1000}")"
  done
}

# cleanup: This function is called when the script exits (e.g., via Ctrl+C).
# It kills all background processes and prints a summary message.
cleanup() {
  local code=$?
  # Disable the trap to prevent recursion.
  trap - INT TERM EXIT
  # Terminate all background collector processes.
  for pid in "${pids[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  log "Logs saved in: $OUTDIR"
  # Provide a convenient command to create a compressed archive of the logs.
  log "Pack to share: tar -czf \"$OUTDIR.tgz\" -C \"$(dirname "$OUTDIR")\" \"$(basename "$OUTDIR")\""
  exit $code
}

# --- Main Execution ---

banner "ASUS Duo BT trace starting"
# Log some initial system information.
log "Kernel: $(uname -r)"
log "BlueZ:  $(bluetoothctl --version 2>/dev/null || echo unknown)"
log "Session: XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-?} DESKTOP_SESSION=${DESKTOP_SESSION:-?}"
log "hid_asus IDs present? $(modinfo hid_asus 2>/dev/null | grep -Eio '0x1b2c|0x1b2d|0x1bf2|0x1bf3|ux8406|zenbook' | tr '\n' ' ' || echo none)"

# Detect the keyboard's MAC address.
detect_mac
log "Using keyboard MAC: $MAC"
OBJ=$(dev_obj_path); log "BlueZ object: $OBJ"

# Start all background data collectors.
start_btmon
start_dbusmon
start_udevmon
start_journalk
start_libinput_stream

# Take an initial set of snapshots right away.
snapshot_input_props
snapshot_bt_props
snapshot_power

# Allow the user to insert manual markers into the logs.
# This is useful for correlating an event in the logs with a user action.
# Any text typed into the console followed by Enter will create a marker.
{
  while IFS= read -r line; do
    [[ -z "$line" ]] && line="MARK"
    log "USER-$line"
    echo "---- USER-$line @ $(date +%F\ %T) ----" >> "$OUTDIR/marks.txt"
    # Take a fresh set of snapshots whenever a marker is added.
    snapshot_input_props
    snapshot_bt_props
    snapshot_power
  done
} < /dev/stdin & pids+=($!)

# Start the periodic snapshot sampler in the background.
sampler & pids+=($!)

# Set up the cleanup function to run on script exit.
trap cleanup INT TERM EXIT

# Wait for all background processes to finish.
# Since the sampler runs forever, this effectively waits until Ctrl+C is pressed.
wait
