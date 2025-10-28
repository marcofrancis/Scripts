#!/usr/bin/env bash
# ASUS Zenbook Duo keyboard (USB 0b05:1bf2) – set backlight level 0..3
# Uses HID SET_REPORT (Feature) with Report ID 0x5A on interface 4.
set -euo pipefail

# Parse level (default 3)
LEVEL="${1:-3}"
if [[ ! "$LEVEL" =~ ^[0-3]$ ]]; then
  echo "Usage: $(basename "$0") [0|1|2|3]"
  echo "  0=off, 1=low, 2=medium, 3=max (default)"
  exit 2
fi

# Prefer your hhd venv Python; else system python3
PY="$HOME/.local/share/hhd/venv/bin/python"; [[ -x "$PY" ]] || PY="$(command -v python3)"

"$PY" - <<PY
import sys, subprocess

VID, PID   = 0x0b05, 0x1bf2
IFACE      = 4                 # HID interface index for backlight control
RID        = 0x5A              # Report ID
WVALUE     = (0x03 << 8) | RID # 0x035A = Feature report + Report ID
try:
    LEVEL  = int(${LEVEL})
except Exception:
    print("[error] level must be 0..3"); sys.exit(2)
if not (0 <= LEVEL <= 3):
    print("[error] level must be 0..3"); sys.exit(2)

WLEN       = 16
# Payload: 5A BA C5 C4 <LEVEL> then zeros to 16 bytes
DATA = bytes([RID, 0xBA, 0xC5, 0xC4, LEVEL] + [0x00]*(WLEN-5))

def ensure_pyusb():
    try:
        import usb  # noqa
        return True
    except Exception:
        try: subprocess.check_call([sys.executable, "-m", "ensurepip", "--upgrade"])
        except Exception: pass
        in_venv = (getattr(sys, "real_prefix", None) is not None) or (sys.prefix != getattr(sys, "base_prefix", sys.prefix))
        cmd = [sys.executable, "-m", "pip", "install", "pyusb"]
        if not in_venv: cmd.insert(3, "--user")
        print("[setup] Installing pyusb…")
        subprocess.check_call(cmd)
        import usb  # noqa
        return True

if not ensure_pyusb():
    sys.exit(1)

import usb.core, usb.util
from usb.core import USBError

# libusb backend
try:
    import usb.backend.libusb1 as libusb1
    backend = libusb1.get_backend()
    if backend is None:
        print("[error] libusb backend missing (install libusb1).", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f"[error] libusb1 backend load failed: {e}", file=sys.stderr)
    sys.exit(1)

dev = usb.core.find(idVendor=VID, idProduct=PID, backend=backend)
if dev is None:
    print("[info] Keyboard 0b05:1bf2 not found over USB (attach via pogo/USB-C).")
    sys.exit(0)

print(f"Setting backlight level {LEVEL} (0..3) on {hex(VID)}:{hex(PID)}; interface={IFACE}, RID=0x{RID:02X}")

def send(attached: bool):
    # bmRequestType=0x21 (Host->Dev | Class | Interface), bRequest=0x09 (SET_REPORT), wIndex=interface
    return dev.ctrl_transfer(0x21, 0x09, WVALUE, IFACE, DATA, timeout=500)

# Try with kernel driver attached
try:
    sent = send(attached=True)
    print(f"[ok] SET_REPORT (attached) -> {sent} bytes")
    print("✓ Done.")
    sys.exit(0)
except USBError as e:
    print(f"[warn] attached send failed: {e}")

# Detach/claim, then send
reattach = False
try:
    if hasattr(dev, "is_kernel_driver_active") and dev.is_kernel_driver_active(IFACE):
        print("[info] Detaching kernel driver on interface", IFACE)
        dev.detach_kernel_driver(IFACE); reattach = True
    try:
        usb.util.claim_interface(dev, IFACE)
    except USBError as e:
        print(f"[warn] claim_interface({IFACE}) failed: {e}")

    sent = send(attached=False)
    print(f"[ok] SET_REPORT (detached/claimed) -> {sent} bytes")
    print("✓ Done.")
    sys.exit(0)
except USBError as e:
    print(f"[error] send failed after detach/claim: {e}")
    sys.exit(1)
finally:
    try: usb.util.release_interface(dev, IFACE)
    except Exception: pass
    if reattach:
        try:
            usb.util.dispose_resources(dev)
            dev.attach_kernel_driver(IFACE)
            print("[info] Kernel driver reattached.")
        except Exception:
            pass
PY
