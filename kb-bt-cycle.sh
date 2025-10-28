#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zenbook-kb"
STATE_FILE="${STATE_DIR}/bt_level"

mkdir -p "${STATE_DIR}"
if [[ -s "${STATE_FILE}" && "$(cat "${STATE_FILE}")" =~ ^[0-3]$ ]]; then
  CUR="$(cat "${STATE_FILE}")"
else
  CUR=3  # so next is 0
fi

# Next in cycle
case "${CUR}" in
  0) NEXT=1 ;;
  1) NEXT=2 ;;
  2) NEXT=3 ;;
  3) NEXT=0 ;;
esac

echo "${NEXT}" > "${STATE_FILE}"
exec /home/marco/Scripts/duo-bt-brightness.sh "${NEXT}"
