#!/usr/bin/env bash
#
# Set the keyboard backlight brightness for the ASUS Zenbook Duo keyboard when
# it is connected via USB (docked).
#
# This script sends a low-level USB HID "Feature Report" command to the keyboard
# to control its backlight. It's a hybrid script that uses a Bash wrapper to
# execute an embedded Python script.
#
# The Python portion handles the USB communication and requires the 'pyusb'
# library, which it will attempt to install automatically if it's missing.
#
# Usage:
#   ./duo-usb-brightness.sh [level]
#   level: A number from 0 (off) to 3 (maximum brightness). Defaults to 3.
#

# Stop on first error, undefined variable, or pipe failure
set -euo pipefail

# --- Argument Parsing ---

# Read the brightness level from the first command-line argument. Default to 3 (max).
LEVEL="${1:-3}"
# Validate that the level is a single digit from 0 to 3.
if [[ ! "$LEVEL" =~ ^[0-3]$ ]]; then
  echo "Usage: $(basename "$0") [0|1|2|3]"
  echo "  0=off, 1=low, 2=medium, 3=max (default)"
  exit 2
fi

# --- Python Interpreter Selection ---

# Prefer using the Python executable from the 'hhd' virtual environment if it
# exists, as it's likely to have the necessary dependencies. Otherwise, fall
# back to the system's default 'python3'.
PY="$HOME/.local/share/hhd/venv/bin/python"
if ! [[ -x "$PY" ]]; then
  PY="$(command -v python3)"
fi
if ! [[ -x "$PY" ]]; then
  echo "Error: python3 not found." >&2
  exit 1
fi

# --- Embedded Python Script ---

# Execute the Python script using a 'here document'.
# This allows embedding Python code directly within the Bash script.
# The Bash variable $LEVEL is safely passed into the Python script.
"$PY" - <<PY
import sys
import subprocess
import usb.core
import usb.util
from usb.core import USBError

# --- USB Device & Command Configuration ---

# USB Vendor and Product ID for the ASUS Zenbook Duo Keyboard.
VID, PID = 0x0b05, 0x1bf2

# The specific HID interface on the keyboard that handles backlight control.
IFACE = 4

# The HID Report ID for the backlight command.
RID = 0x5A

# The wValue for the control transfer, combining Report Type and Report ID.
# 0x0300 indicates a "Feature" report.
WVALUE = (0x03 << 8) | RID  # Becomes 0x035A

# The total length of the HID report payload in bytes.
WLEN = 16

# --- Payload Construction ---

try:
    # Read the brightness level passed from the Bash script.
    LEVEL = int(${LEVEL})
    if not (0 <= LEVEL <= 3):
        raise ValueError()
except Exception:
    print(f"[error] Invalid brightness level: ${LEVEL}. Must be 0-3.", file=sys.stderr)
    sys.exit(2)

# The payload is a specific sequence of bytes required by the keyboard's firmware.
# It starts with the Report ID, followed by a "magic" sequence (BA C5 C4),
# then the brightness level, and is padded with zeros to the required length.
DATA = bytes([RID, 0xBA, 0xC5, 0xC4, LEVEL] + [0x00] * (WLEN - 5))

# --- Dependency Management ---

def ensure_pyusb():
    """Checks for pyusb and installs it if missing."""
    try:
        import usb  # Try to import the library.
        return True
    except ImportError:
        # If it fails, attempt to install it using pip.
        print("[setup] pyusb not found. Attempting to install...")
        # Determine if we are in a virtual environment.
        in_venv = (hasattr(sys, 'real_prefix') or
                   (hasattr(sys, 'base_prefix') and sys.base_prefix != sys.prefix))
        cmd = [sys.executable, "-m", "pip", "install", "pyusb"]
        # Use '--user' flag if not in a venv to avoid permission errors.
        if not in_venv:
            cmd.insert(3, "--user")
        
        try:
            subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print("[setup] pyusb installed successfully.")
            import usb # pylint: disable=reimported
            return True
        except (subprocess.CalledProcessError, ImportError) as e:
            print(f"[error] Failed to install or import pyusb: {e}", file=sys.stderr)
            print("Please install it manually: 'pip install pyusb'", file=sys.stderr)
            return False

# --- Main Logic ---

# Ensure pyusb is available before proceeding.
if not ensure_pyusb():
    sys.exit(1)

# Find the USB device by its Vendor and Product ID.
dev = usb.core.find(idVendor=VID, idProduct=PID)

if dev is None:
    # This is not an error; the keyboard might be detached. Exit gracefully.
    print("[info] Keyboard 0b05:1bf2 not found via USB (it may be detached).")
    sys.exit(0)

print(f"Found keyboard. Setting backlight level to {LEVEL}...")

# This is the core USB control transfer command.
# Parameters:
#   0x21: Request type - Host-to-Device, Class-specific, Interface recipient.
#   0x09: Request - SET_REPORT, a standard HID request.
#   WVALUE: (0x035A) Specifies Feature Report with Report ID 0x5A.
#   IFACE:  The interface number to send the command to.
#   DATA:   The 16-byte payload we constructed.
try:
    # First, try to send the command directly. This often works without needing
    # to detach the kernel's default HID driver.
    sent_bytes = dev.ctrl_transfer(0x21, 0x09, WVALUE, IFACE, DATA, timeout=500)
    print(f"[ok] Sent {sent_bytes} bytes successfully (kernel driver attached).")

except USBError as e:
    # If the first attempt fails (e.g., with "Resource busy"), it means the
    # kernel driver has exclusive control of the interface. We need to
    # detach it, send our command, and then reattach it.
    print(f"[warn] Control transfer failed (is kernel driver active?): {e}")
    print("[info] Retrying with kernel driver detachment...")
    
    reattach = False
    try:
        if dev.is_kernel_driver_active(IFACE):
            print(f"[info] Detaching kernel driver from interface {IFACE}.")
            dev.detach_kernel_driver(IFACE)
            reattach = True

        # After detaching, we can claim the interface for our script's exclusive use.
        usb.util.claim_interface(dev, IFACE)
        
        # Retry the control transfer.
        sent_bytes = dev.ctrl_transfer(0x21, 0x09, WVALUE, IFACE, DATA, timeout=500)
        print(f"[ok] Sent {sent_bytes} bytes successfully (kernel driver detached).")
        
    except USBError as e2:
        print(f"[error] Control transfer failed again: {e2}", file=sys.stderr)
        sys.exit(1)
        
    finally:
        # This block ensures that we always release the interface and reattach
        # the kernel driver, even if errors occur. This is crucial to return
        # the keyboard to its normal operational state.
        try:
            usb.util.release_interface(dev, IFACE)
            print("[info] Interface released.")
        except USBError as e:
            print(f"[warn] Failed to release interface: {e}", file=sys.stderr)

        if reattach:
            try:
                dev.attach_kernel_driver(IFACE)
                print("[info] Kernel driver reattached.")
            except USBError as e:
                print(f"[warn] Failed to reattach kernel driver: {e}", file=sys.stderr)
                print("[warn] The keyboard may not function correctly until re-plugged.", file=sys.stderr)
finally:
    # Dispose of the device object to clean up resources.
    usb.util.dispose_resources(dev)

print("✓ Done.")
PY
