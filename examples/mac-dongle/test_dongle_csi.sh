#!/usr/bin/env bash
# =============================================================================
# test_dongle_csi.sh — empirically determine whether a Realtek AX900 (RTL8851BU,
# rtw89) USB WiFi dongle can be used for WiFi SENSING on a Linux host
# (e.g. the Ato RK3308 device). Run this ON THE ROCKCHIP, not the Mac —
# macOS can't even mode-switch or drive this chip.
#
# It tests, in order, the two sensing paths and reports a clear verdict:
#   1. Raw CSI export     — needed for heartrate/breathing (ESP32-grade signal)
#   2. Beamforming feedback (BFI) in monitor mode — RuView's BFLD path; gives
#      presence/motion (NOT heartrate), but needs no CSI firmware
#
# Usage:
#   sudo bash test_dongle_csi.sh            # full test
#   sudo bash test_dongle_csi.sh --capture  # also do a 20s BFI sniff if monitor works
#
# Safe & read-only-ish: it mode-switches the dongle, toggles the interface into
# monitor mode, optionally captures to /tmp, then restores managed mode.
# =============================================================================
set -uo pipefail

CAPTURE=0; [ "${1:-}" = "--capture" ] && CAPTURE=1
PASS="\033[32m"; FAIL="\033[31m"; WARN="\033[33m"; OFF="\033[0m"
ok(){   echo -e "  ${PASS}[ OK ]${OFF} $*"; }
no(){   echo -e "  ${FAIL}[ NO ]${OFF} $*"; }
warn(){ echo -e "  ${WARN}[ ?? ]${OFF} $*"; }
hr(){ printf '%.0s-' {1..72}; echo; }

CSI_OK=0; MONITOR_OK=0; BFI_FRAMES=0; CHIP="unknown"; WLAN=""

if [ "$(id -u)" != "0" ]; then
  echo "Run as root: sudo bash $0 ${1:-}"; exit 1
fi

echo "========================================================================"
echo " RTL8851BU / AX900 dongle — WiFi-sensing capability probe"
echo " $(date)  host=$(uname -srm)"
echo "========================================================================"

# --- 0. tooling ----------------------------------------------------------------
echo; echo "## 0. Tooling"
for t in lsusb iw ip usb_modeswitch tcpdump; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else warn "$t MISSING (apt/opkg install $t)"; fi
done

# --- 1. mode-switch out of CD/driver-disk mode --------------------------------
echo; echo "## 1. Mode-switch (0bda:1a2b CD mode -> WiFi NIC)"
if lsusb 2>/dev/null | grep -qi '0bda:1a2b'; then
  warn "Dongle is in CD-ROM/driver-disk mode — switching..."
  usb_modeswitch -KW -v 0bda -p 1a2b >/dev/null 2>&1 || true
  sleep 3
fi
echo "  Current Realtek USB IDs:"; lsusb 2>/dev/null | grep -i '0bda:' | sed 's/^/    /' || true

# --- 2. driver bind + chip id --------------------------------------------------
echo; echo "## 2. Driver / chip"
if lsmod 2>/dev/null | grep -q '^rtw89'; then ok "rtw89 module loaded"; else warn "rtw89 not loaded (modprobe rtw89_8851bu ?)"; fi
CHIP=$(dmesg 2>/dev/null | grep -ioE 'rtl885[0-9][a-z]*u?' | tail -1); CHIP=${CHIP:-unknown}
echo "  dmesg chip hint: ${CHIP}"
dmesg 2>/dev/null | grep -i rtw89 | tail -4 | sed 's/^/    /'
# find the wlan interface backed by rtw89
for dev in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
  drv=$(readlink -f "/sys/class/net/$dev/device/driver" 2>/dev/null)
  case "$drv" in *rtw89*) WLAN="$dev";; esac
done
[ -z "$WLAN" ] && WLAN=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
echo "  WiFi interface under test: ${WLAN:-<none found>}"
[ -z "$WLAN" ] && { no "No wlan interface — dongle did not enumerate as WiFi. Stopping."; exit 2; }

# --- 3. PATH A: raw CSI export (the heartrate-grade signal) --------------------
echo; echo "## 3. PATH A — raw CSI export (needed for HEARTRATE/breathing)"
PHY=$(iw dev "$WLAN" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
DBG="/sys/kernel/debug/ieee80211/${PHY}/rtw89"
if [ -d "$DBG" ]; then
  echo "  rtw89 debugfs nodes ($DBG):"; ls -1 "$DBG" 2>/dev/null | sed 's/^/    /'
  if ls "$DBG" 2>/dev/null | grep -qiE 'csi|phy_sts|chan_info|beamform'; then
    warn "Found a possibly-CSI-related debugfs node — worth manual inspection."
  else
    no "No CSI / channel-info node exposed by rtw89 (expected — Realtek doesn't export CSI)."
  fi
else
  no "No rtw89 debugfs dir — no CSI interface. (mount -t debugfs none /sys/kernel/debug to be sure)"
fi
echo "  => Raw per-packet CSI from this chip: not available via mainline rtw89."
echo "     Heartrate needs this. (CSI_OK stays 0.)"

# --- 4. PATH B: monitor mode -> beamforming feedback (RuView BFLD, presence) ---
echo; echo "## 4. PATH B — monitor mode + BFI sniffing (RuView BFLD: presence/motion only)"
MODES=$(iw phy "$PHY" info 2>/dev/null | sed -n '/Supported interface modes/,/Band /p')
echo "$MODES" | grep -E '\* ' | sed 's/^/    /'
if echo "$MODES" | grep -qiE '\*\s*monitor'; then
  ok "Chip ADVERTISES monitor mode. Trying to actually enter it..."
  ip link set "$WLAN" down 2>/dev/null
  if iw dev "$WLAN" set type monitor 2>/tmp/mon.err && ip link set "$WLAN" up 2>/dev/null; then
    TYPE=$(iw dev "$WLAN" info 2>/dev/null | awk '/type/{print $2}')
    if [ "$TYPE" = "monitor" ]; then
      MONITOR_OK=1; ok "Interface is now in MONITOR mode — the BFI path is viable on this dongle."
    else warn "set type monitor returned but type=$TYPE"; fi
  else
    no "Kernel REFUSED monitor mode: $(cat /tmp/mon.err 2>/dev/null). BFI path dead on this dongle."
  fi
else
  no "Chip does NOT advertise monitor mode under rtw89 → BFI/BFLD path not available."
fi

# --- 5. optional BFI capture ---------------------------------------------------
if [ "$MONITOR_OK" = 1 ] && [ "$CAPTURE" = 1 ]; then
  echo; echo "## 5. 20s capture — hunting for 802.11ac/ax compressed beamforming action frames"
  echo "     (Need a Wi-Fi AP + active client doing beamforming nearby. Set channel to the AP's.)"
  iw dev "$WLAN" set channel 36 80MHz 2>/dev/null || iw dev "$WLAN" set channel 6 2>/dev/null || true
  # subtype action == 0xd0; VHT/HE compressed beamforming are action (no-ack) frames
  timeout 20 tcpdump -i "$WLAN" -nn -c 200 'type mgt subtype action or type mgt subtype action-ack' \
      -w /tmp/bfi.pcap 2>/dev/null
  BFI_FRAMES=$(tcpdump -r /tmp/bfi.pcap 2>/dev/null | wc -l | tr -d ' ')
  echo "  Captured $BFI_FRAMES action(-ish) frames -> /tmp/bfi.pcap"
  echo "  Inspect in Wireshark with filter:  wlan.vht.action or wlan.he_action  (compressed beamforming)"
  [ "$BFI_FRAMES" -gt 0 ] && warn "If these include compressed-beamforming reports, RuView BFLD can ingest them."
fi

# restore
ip link set "$WLAN" down 2>/dev/null; iw dev "$WLAN" set type managed 2>/dev/null
ip link set "$WLAN" up 2>/dev/null

# --- 6. verdict ----------------------------------------------------------------
echo; hr; echo " VERDICT for ${CHIP} (${WLAN})"; hr
if [ "$CSI_OK" = 1 ]; then
  echo -e "  ${PASS}HEARTRATE: possible${OFF} — raw CSI export was found (unexpected!). Wire it to"
  echo    "             RuView's BreathingExtractor/HeartRateExtractor."
else
  echo -e "  ${FAIL}HEARTRATE: NOT possible via this dongle${OFF} — no raw CSI from rtw89."
  echo    "             Use an ESP32-S3 (USB serial) or 60GHz mmWave sensor instead."
fi
if [ "$MONITOR_OK" = 1 ]; then
  echo -e "  ${WARN}PRESENCE/MOTION: plausible${OFF} — monitor mode works, so RuView BFLD (BFI"
  echo    "             sniffing) can run. Needs beamforming traffic in the room. No vitals."
else
  echo -e "  ${FAIL}PRESENCE via BFI: NOT available${OFF} — this dongle won't do monitor mode."
fi
hr
echo "  Bottom line: for HEARTRATE, this dongle is the wrong tool on any OS."
echo "  Best path on the RK3308: ESP32-S3 CSI or MR60BHA2 mmWave over UART -> RuView."
