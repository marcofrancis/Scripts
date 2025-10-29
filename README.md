
# ASUS Zenbook Duo Keyboard Scripts

This repository contains a collection of scripts to manage the detachable
Bluetooth keyboard of the ASUS Zenbook Duo on Linux. These scripts handle
backlight control for both USB (docked) and Bluetooth (detached) modes,
automatic screen management, and troubleshooting for Bluetooth connectivity.

## Core Concepts

- **State File**: A central file, `kb-level.state`, stores the last known
  brightness level (0-3). This allows different scripts to synchronize the
  backlight state.
- **Lock File**: To prevent race conditions where multiple scripts might try to
  modify the state file simultaneously, a lock file (`kb-level.state.lock`) is
  used to ensure operations are atomic.
- **Hybrid Scripts**: Some scripts, like `duo-usb-brightness.sh`, are hybrid
  Bash/Python scripts. A Bash wrapper handles setup and environment checks,
  while an embedded Python script manages low-level USB communication.

## Scripts Overview

### Backlight Control

-   **`duo-bt-brightness.sh`**: Sets the keyboard backlight brightness when
    connected via Bluetooth. It communicates with the keyboard using `bluetoothctl`
    to send a special GATT command. It can auto-discover the keyboard's MAC
    address if not provided.
    -   **Usage**: `./duo-bt-brightness.sh <0|1|2|3>`

-   **`duo-usb-brightness.sh`**: Sets the keyboard backlight brightness when docked
    (connected via USB). It uses a low-level USB HID command via an embedded
    Python script and the `pyusb` library.
    -   **Usage**: `./duo-usb-brightness.sh <0|1|2|3>`

### Brightness Cycle & Presets

These are simple wrapper scripts, often intended to be bound to keyboard shortcuts.

-   **`kb-cycle.sh`**: Toggles the USB keyboard backlight between off (0) and max (3).
-   **`kb-bt-cycle.sh`**: Toggles the Bluetooth keyboard backlight between off (0) and max (3).
-   **`kb-max.sh`**: Sets the USB keyboard backlight to its maximum level (3).
-   **`kb-off.sh`**: Turns the USB keyboard backlight off (sets level to 0).

### Automation and Watchers

-   **`duo-kbd-watch.sh`**: The core automation script. It runs in the background,
    monitoring for USB events to detect when the keyboard is docked or undocked.
    -   **When docked**: It disables the bottom laptop screen and sets the
        backlight brightness via USB.
    -   **When undocked**: It re-enables the bottom screen and sets the backlight
        brightness via Bluetooth.
    -   It supports both KDE (`kscreen-doctor`) and GNOME (`gnome-monitor-config`)
        for display management.

### Troubleshooting

-   **`duo-bt-trace.sh`**: A comprehensive diagnostic tool for troubleshooting
    Bluetooth issues. It captures logs from multiple sources simultaneously,
    including `btmon`, `dbus-monitor`, kernel messages, and `udev`, saving them
    to a timestamped directory for analysis.

-   **`repair-touchpad.sh`**: Automates the process of re-pairing the keyboard.
    This is useful if the touchpad or keyboard stops responding. It has a "soft"
    mode that re-pairs without restarting services and a "hard" mode that
    restarts the Bluetooth service and clears its cache for a cleaner pairing.

## Setup

1.  **Dependencies**: Ensure you have `bluetoothctl`, `pyusb`, and a display
    management tool (`kscreen-doctor` for KDE or `gnome-monitor-config` for GNOME)
    installed. The `duo-usb-brightness.sh` script will attempt to install `pyusb`
    automatically if it's missing.
2.  **Configuration**: Review the configuration variables at the top of each
    script. You may need to adjust the Bluetooth MAC address, USB product IDs, or
    display output names (`eDP-1`, `eDP-2`) to match your specific hardware.
3.  **Permissions**: Make sure all `.sh` files are executable:
    ```bash
    chmod +x *.sh
    ```
4.  **Running the Watcher**: To enable the automatic screen and backlight
    management, run the watcher script in the background. You may want to add
    this to your desktop environment's startup applications.
    ```bash
    ./duo-kbd-watch.sh &
    ```
