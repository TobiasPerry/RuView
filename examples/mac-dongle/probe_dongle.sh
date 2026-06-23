#!/usr/bin/env bash
# probe_dongle.sh — inventory USB/WiFi state on macOS to assess CSI feasibility.
# Usage: bash probe_dongle.sh
set -uo pipefail

echo "=================================================================="
echo " RuView dongle probe — $(date)"
echo "=================================================================="

echo; echo "## USB devices (vendor/product) ----------------------------------"
ioreg -p IOUSB -l -w 0 2>/dev/null \
  | grep -iE '"USB Product Name"|"USB Vendor Name"|"idVendor"|"idProduct"' \
  | sed 's/^[[:space:]]*//'

echo; echo "## Network hardware ports ----------------------------------------"
networksetup -listallhardwareports 2>/dev/null

echo; echo "## WiFi interface (en0) ------------------------------------------"
networksetup -getairportnetwork en0 2>/dev/null || true

echo; echo "## Heuristic check for a Realtek WiFi dongle in driver-disk mode --"
if ioreg -p IOUSB -l -w 0 2>/dev/null | grep -qiE '"USB Vendor Name" = "Realtek"'; then
  echo "  Realtek USB device present."
  echo "  If it shows as 'DISK' / 'CD-ROM' it is in install-disk mode and has NOT"
  echo "  become a WiFi NIC. On Apple Silicon macOS there is no driver to switch"
  echo "  it, and no chipset on macOS exposes CSI. See FINDINGS.md."
else
  echo "  No Realtek USB device detected right now."
fi

echo; echo "## Verdict -------------------------------------------------------"
echo "  macOS exposes NO Channel State Information for any WiFi adapter."
echo "  => Vital-sign sensing through a USB WiFi dongle on this Mac is not"
echo "     possible. Use an ESP32-S3 over USB serial as the CSI source."
echo "=================================================================="
