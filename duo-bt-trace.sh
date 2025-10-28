#!/usr/bin/env bash
# ASUS Zenbook Duo detachable keyboard (BT) tracer
# Captures BlueZ + kernel + udev + input/libinput + power hints in one place.
# Works on KDE/Bazzite/Fedora. Runs until Ctrl+C.
#
# Optional env:
#   DUO_KB_MAC=FE:1A:DA:F8:02:AF   # set if auto-detect fails
#   DUO_KB_NAME="ASUS Zenbook Duo Keyboard"
#   DUO_TRACE_DIR=/tmp/duo_custom_trace
#   DUO_POLL_MS=2000               # snapshot period
#   DUO_LIBINPUT=1                 # try libinput stream (may need sudo)
#   DUO_QUIET=1                    # less console spam

set -Eeuo pipefail

NAME="${DUO_KB_NAME:-ASUS Zenbook Duo Keyboard}"
MAC="${DUO_KB_MAC:-}"
OUTDIR="${DUO_TRACE_DIR:-/tmp/duo_bt_trace_$(date +%F_%H-%M-%S)}"
POLL_MS="${DUO_POLL_MS:-2000}"
QUIET="${DUO_QUIET:-0}"
LIBINPUT_STREAM="${DUO_LIBINPUT:-0}"

mkdir -p "$OUTDIR"
LOG="$OUTDIR/trace.log"
TOUCH "$LOG" >/dev/null 2>&1 || true

log(){ printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG"; }
vlog(){ [ "$QUIET" = "1" ] && printf '%s\n' "$*" >>"$LOG" || log "$*"; }
banner(){ printf '\n=== %s ===\n' "$1" | tee -a "$LOG"; }

die(){ log "ERROR: $*"; exit 1; }

# --- helpers ---------------------------------------------------------------

detect_mac() {
  if [[ -n "$MAC" ]]; then return 0; fi
  MAC="$(bluetoothctl devices 2>/dev/null | awk -v pat="$NAME" '$0 ~ pat {print $2; exit}')"
  [[ -n "$MAC" ]] || die "Could not find MAC for '$NAME'. Pair it, or set DUO_KB_MAC=AA:BB:CC:DD:EE:FF"
}

dev_obj_path() { # BlueZ Device1 object path
  printf '/org/bluez/hci0/dev_%s\n' "$(echo "$MAC" | tr ':' '_')"
}

hci_parent_path() {
  local p; p="$(readlink -f /sys/class/bluetooth/hci0/device || true)"
  [[ -n "$p" ]] && printf '%s\n' "$p"
}

event_nodes() {
  # event nodes for BT Mouse/Touchpad only
  awk '
    BEGIN{s=0}
    /^N: Name="ASUS Zenbook Duo Keyboard (Mouse|Touchpad)"/{s=1; next}
    s && /^H: Handlers=/{ while (match($0,/event[0-9]+/)) { print substr($0,RSTART,RLENGTH); $0=substr($0,RSTART+RLENGTH) } s=0 }
  ' /proc/bus/input/devices 2>/dev/null | sort -u
}

snapshot_input_props() {
  local f="$OUTDIR/snap-input.txt"
  {
    echo "--- $(date +%F\ %T) ---"
    grep -i -E 'Asus|ELAN|mouse|touchpad|keyboard' /proc/bus/input/devices 2>/dev/null || true
    for ev in $(event_nodes); do
      local dev="/dev/input/$ev"
      echo "### $dev udev props ###"
      udevadm info -q property -n "$dev" 2>/dev/null | grep -E 'NAME=|ID_INPUT|ID_BUS|ID_PATH|USEC_INITIALIZED' || true
    done
  } >> "$f"
}

snapshot_bt_props() {
  local f="$OUTDIR/snap-bluez.txt" obj; obj="$(dev_obj_path)"
  {
    echo "--- $(date +%F\ %T) ---"
    bluetoothctl info "$MAC" 2>/dev/null || true
    echo "busctl Device1 props:"
    busctl get-property org.bluez "$obj" org.bluez.Device1 Connected       2>/dev/null || true
    busctl get-property org.bluez "$obj" org.bluez.Device1 ServicesResolved 2>/dev/null || true
    busctl get-property org.bluez "$obj" org.bluez.Device1 UUIDs           2>/dev/null || true
  } >> "$f"
}

snapshot_power() {
  local f="$OUTDIR/snap-power.txt" h; h="$(hci_parent_path || true)"
  {
    echo "--- $(date +%F\ %T) ---"
    echo "hci0 parent: ${h:-unknown}"
    if [[ -n "$h" && -e "$h/power/control" ]]; then
      printf 'hci parent power/control = %s\n' "$(cat "$h/power/control" 2>/dev/null || echo '?')"
    fi
    rfkill -o ID,TYPE,SOFT,HARD list 2>/dev/null || true
    # show active autosuspend policy for BT controller if USB
    if [[ -L "$h/../.." && -e "$h/../power/autosuspend_delay_ms" ]]; then
      printf 'autosuspend_delay_ms = %s\n' "$(cat "$h/../power/autosuspend_delay_ms" 2>/dev/null || echo '?')"
    fi
  } >> "$f"
}

# --- background collectors -------------------------------------------------

pids=()

start_btmon() {
  if command -v btmon >/dev/null 2>&1; then
    vlog "btmon → $OUTDIR/btmon.txt"
    stdbuf -oL btmon > "$OUTDIR/btmon.txt" 2>&1 & pids+=($!)
  else
    log "btmon not found; skipping HCI trace"
  fi
}

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

start_udevmon() {
  vlog "udevadm monitor(input) → $OUTDIR/udev.txt"
  udevadm monitor --kernel --udev --subsystem-match=input \
    | stdbuf -oL awk '{print strftime("[%F %T]"), $0}' \
    > "$OUTDIR/udev.txt" 2>&1 & pids+=($!)
}

start_journalk() {
  vlog "journalctl -kf (filtered) → $OUTDIR/kernel.txt"
  journalctl -kf \
    | stdbuf -oL grep -E -i 'hid|asus|uhid|blue|bt|hci|rfkill|input|usb|multitouch' \
    > "$OUTDIR/kernel.txt" 2>&1 & pids+=($!)
}

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

sampler() {
  local i=0
  while :; do
    ((i++)) || true
    snapshot_input_props
    snapshot_bt_props
    snapshot_power
    sleep "$(awk "BEGIN{printf \"%.3f\", $POLL_MS/1000}")"
  done
}

cleanup() {
  local code=$?
  trap - INT TERM EXIT
  for pid in "${pids[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  log "Logs saved in: $OUTDIR"
  log "Pack to share: tar -czf \"$OUTDIR.tgz\" -C \"$(dirname "$OUTDIR")\" \"$(basename "$OUTDIR")\""
  exit $code
}

# --- main ------------------------------------------------------------------

banner "ASUS Duo BT trace starting"
log "Kernel: $(uname -r)"
log "BlueZ:  $(bluetoothctl --version 2>/dev/null || echo unknown)"
log "Session: XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-?} DESKTOP_SESSION=${DESKTOP_SESSION:-?}"
log "hid_asus IDs present? $(modinfo hid_asus 2>/dev/null | grep -Eio '0x1b2c|0x1b2d|0x1bf2|0x1bf3|ux8406|zenbook' | tr '\n' ' ' || echo none)"

detect_mac
log "Using keyboard MAC: $MAC"
OBJ=$(dev_obj_path); log "BlueZ object: $OBJ"

start_btmon
start_dbusmon
start_udevmon
start_journalk
start_libinput_stream

# initial snapshots
snapshot_input_props
snapshot_bt_props
snapshot_power

# interactive markers (optional): type a line to insert a mark
{
  while IFS= read -r line; do
    [[ -z "$line" ]] && line="MARK"
    log "USER-$line"
    echo "---- USER-$line @ $(date +%F\ %T) ----" >> "$OUTDIR/marks.txt"
    # quick one-shot snapshots on mark
    snapshot_input_props
    snapshot_bt_props
    snapshot_power
  done
} < /dev/stdin & pids+=($!)

# periodic sampler
sampler & pids+=($!)

trap cleanup INT TERM EXIT
wait
