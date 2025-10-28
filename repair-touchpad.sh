#!/usr/bin/env bash
set -euo pipefail

# === Config (override via env) ===
MAC="${MAC:-FE:1A:DA:F8:02:AF}"          # exact device MAC to act on
PIN="${PIN:-0000}"                       # PIN/passkey if prompted
ALIAS_MATCH="${ALIAS_MATCH:-ASUS Zenbook Duo Keyboard}"  # safety: alias must contain this
ONLY_HID="${ONLY_HID:-1}"                # require HID/HOGP service UUIDs
HARD="${HARD:-0}"                        # 0 = soft (default, no daemon restart), 1 = hard
LOG="${LOG:-$HOME/Scripts/repair-touchpad.log}"
DEBUG="${DEBUG:-1}"

ts(){ date +"%Y-%m-%d %H:%M:%S%z"; }
log(){ printf "[%s] %s\n" "$(ts)" "$*" | tee -a "$LOG" >/dev/null; [[ "$DEBUG" == "1" ]] && echo "$*"; }
run(){ log ">> $*"; bash -lc "$*" >>"$LOG" 2>&1; }

: >"$LOG"
log "=== START RE-PAIR (soft=${HARD} hard=${HARD}) ==="
log "MAC=$MAC PIN=$PIN ALIAS_MATCH='$ALIAS_MATCH' ONLY_HID=$ONLY_HID DEBUG=$DEBUG"

command -v bluetoothctl >/dev/null || { echo "bluetoothctl not found"; exit 1; }

# Ensure adapter up + powered (don’t restart daemon by default)
run "rfkill unblock bluetooth || true"
run "bluetoothctl power on || true"

# Basic info
INFO="$(bluetoothctl info "$MAC" 2>/dev/null || true)"
if [[ -z "$INFO" ]]; then
  log "NOTE: Device not in controller cache yet. That’s fine; continuing."
else
  # Safety 1: alias must match (so we don’t touch headphones, etc.)
  if [[ -n "$ALIAS_MATCH" ]]; then
    ALIAS="$(printf "%s" "$INFO" | awk -F': ' '/Alias:/ {print substr($0, index($0,$2))}')"
    if [[ "$ALIAS" != *"$ALIAS_MATCH"* ]]; then
      log "ABORT: Alias '$ALIAS' does not contain '$ALIAS_MATCH'."
      exit 20
    fi
  fi
  # Safety 2: require HID/HOGP service UUIDs if requested
  if [[ "$ONLY_HID" == "1" ]]; then
    if ! (printf "%s" "$INFO" | grep -qiE 'UUID:.*(Human-Interface|00001124-0000-1000-8000-00805f9b34fb|00001812-0000-1000-8000-00805f9b34fb)'); then
      log "ABORT: Device does not advertise HID/HOGP UUIDs (1124/1812)."
      exit 21
    fi
  fi
fi

# Register non-interactive agent (no prompts)
run "bluetoothctl agent off || true"
run "bluetoothctl agent NoInputNoOutput"
run "bluetoothctl default-agent"

# SOFT path: do NOT restart bluetoothd (keeps KDE applet happy)
soft_repair() {
  run "bluetoothctl untrust $MAC || true"
  run "bluetoothctl remove  $MAC || true"
  # Ensure device is pairable on our side; avoid global scanning unless needed
  run "bluetoothctl pairable on || true"
  # attempt pair; if device isn’t advertising, you may need to put it in pairing mode
  set +e
  bluetoothctl pair "$MAC" >>"$LOG" 2>&1
  rc=$?
  set -e
  log "pair() exit=$rc"
  return $rc
}

# HARD path: bounce daemon + wipe host cache for this MAC, then pair again
hard_repair() {
  # Find adapter address (controller MAC)
  ADAPTER="$(bluetoothctl list | awk '{print $2; exit}')"
  if [[ -z "$ADAPTER" ]]; then
    run "bluetoothctl power on || true"
    ADAPTER="$(bluetoothctl list | awk '{print $2; exit}')"
  fi
  [[ -n "$ADAPTER" ]] || { log "ABORT: No adapter found"; return 2; }

  # Restart daemon & ensure Powered=on
  run "sudo systemctl restart bluetooth"
  run "bluetoothctl power on || true"

  # Wipe cached record for THIS MAC only
  run "sudo rm -rf '/var/lib/bluetooth/$ADAPTER/$MAC' || true"

  # Re-register agent after restart
  run "bluetoothctl agent off || true"
  run "bluetoothctl agent NoInputNoOutput"
  run "bluetoothctl default-agent"
  run "bluetoothctl pairable on || true"

  set +e
  bluetoothctl pair "$MAC" >>"$LOG" 2>&1
  rc=$?
  set -e
  log "pair(hard) exit=$rc"
  return $rc
}

# Attempt soft repair first (default)
if soft_repair; then
  SOFT_OK=1
else
  SOFT_OK=0
fi

if [[ $SOFT_OK -ne 1 && "$HARD" == "1" ]]; then
  log "Soft re-pair failed; escalating to HARD…"
  if ! hard_repair; then
    log "HARD re-pair failed. Device likely needs to be in pairing mode."
    echo "Pair failed. Put the keyboard/touchpad in pairing mode, then re-run:"
    echo "  DEBUG=1 HARD=1 MAC=$MAC ~/Scripts/repair-touchpad.sh"
    exit 10
  fi
fi

# Trust + connect (won’t affect other devices)
run "bluetoothctl trust $MAC"
set +e
bluetoothctl connect "$MAC" >>"$LOG" 2>&1
CONN_RC=$?
set -e
log "connect() exit=$CONN_RC"

# Final status
run "bluetoothctl info $MAC || true"
log "=== END RE-PAIR ==="

if [[ $CONN_RC -eq 0 ]]; then
  echo "Re-pair OK → Connected to $MAC."
else
  echo "Re-pair OK → Paired but connect failed. Try: bluetoothctl connect $MAC"
fi

# Optional: if KDE applet *still* looks out of sync, you can refresh BlueDevil:
# (safe to run; does NOT toggle the adapter)
#   qdbus org.kde.kded5 /kded unloadModule bluedevil; qdbus org.kde.kded5 /kded loadModule bluedevil
