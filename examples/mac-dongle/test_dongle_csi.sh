#!/usr/bin/env bash
# =============================================================================
# test_dongle_csi.sh — empirically determine whether a Realtek AX900 (RTL8851BU,
# rtw89) USB WiFi dongle can be used for WiFi SENSING on a Linux host
# (e.g. the Ato RK3308 / Yocto device). Run this ON THE ROCKCHIP, not the Mac —
# macOS can't even mode-switch or drive this chip.
#
# Tests the two sensing paths and prints a clear verdict:
#   PATH A  Raw CSI export       — needed for HEARTRATE/breathing (ESP32-grade)
#   PATH B  Beamforming feedback — RuView's BFLD path; presence/motion, NOT vitals
#
# Usage:
#   sudo bash test_dongle_csi.sh             # full probe
#   sudo bash test_dongle_csi.sh --capture   # also 20s BFI sniff if monitor works
#
# Needs (install via opkg on Yocto, or apt on Debian): iw usbutils usb-modeswitch
#       tcpdump.  Missing tools are reported, not fatal (except iw for PATH B).
# =============================================================================

# Re-exec under bash if launched with sh (Yocto default shell is often BusyBox).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -uo pipefail

CAPTURE=0; [ "${1:-}" = "--capture" ] && CAPTURE=1
if [ -t 1 ]; then P="\033[32m"; F="\033[31m"; W="\033[33m"; O="\033[0m"; else P=""; F=""; W=""; O=""; fi
ok(){   echo -e "  ${P}[ OK ]${O} $*"; }
no(){   echo -e "  ${F}[ NO ]${O} $*"; }
warn(){ echo -e "  ${W}[ ?? ]${O} $*"; }
LINE="------------------------------------------------------------------------"

CSI_OK=0; MONITOR_OK=0; BFI_FRAMES=0; CHIP="unknown"; WLAN=""

if [ "$(id -u)" != "0" ]; then echo "Run as root: sudo bash $0 ${1:-}"; exit 1; fi

# package-manager-aware install hint
if   command -v opkg >/dev/null 2>&1; then PM="opkg install"
elif command -v apt  >/dev/null 2>&1; then PM="apt install -y"
else PM="<your package manager> install"; fi

echo "========================================================================"
echo " RTL8851BU / AX900 dongle — WiFi-sensing capability probe"
echo " host=$(uname -srm)  kernel=$(uname -r)"
echo "========================================================================"

# --- 0. tooling ---------------------------------------------------------------
echo; echo "## 0. Tooling   (install missing: $PM <pkg>)"
have(){ command -v "$1" >/dev/null 2>&1; }
for t in iw lsusb usb_modeswitch tcpdump; do
  if have "$t"; then ok "$t"; else warn "$t MISSING"; fi
done
if ! have iw; then
  no "iw is REQUIRED for the monitor-mode (PATH B) test. Install it and re-run:"
  echo "      $PM iw"
fi

# --- 1. mode-switch out of CD/driver-disk mode --------------------------------
echo; echo "## 1. Mode-switch (0bda:1a2b CD mode -> WiFi NIC)"
if have lsusb && lsusb | grep -qi '0bda:1a2b'; then
  warn "Dongle in CD-ROM/driver-disk mode."
  if have usb_modeswitch; then
    echo "  switching..."; usb_modeswitch -KW -v 0bda -p 1a2b >/dev/null 2>&1 || true; sleep 3
  else
    no "usb_modeswitch missing — can't leave CD mode. Install: $PM usb-modeswitch"
  fi
fi
if have lsusb; then echo "  Realtek USB IDs now:"; lsusb | grep -i '0bda:' | sed 's/^/    /' || true; fi

# --- 2. driver bind + chip id -------------------------------------------------
echo; echo "## 2. Driver / chip"
if lsmod 2>/dev/null | grep -q '^rtw89'; then ok "rtw89 module loaded"
else warn "rtw89 not loaded — try: modprobe rtw89_8851bu"; modprobe rtw89_8851bu 2>/dev/null || true; fi
CHIP=$(dmesg 2>/dev/null | grep -ioE 'rtl885[0-9][a-z]*u?' | tail -1); CHIP=${CHIP:-unknown}
echo "  dmesg chip hint: ${CHIP}"
dmesg 2>/dev/null | grep -i rtw89 | tail -4 | sed 's/^/    /'
# find the wlan interface backed by rtw89 (prefer rtw89; else first wifi dev)
if have iw; then
  for dev in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
    drv=$(readlink -f "/sys/class/net/$dev/device/driver" 2>/dev/null)
    case "$drv" in *rtw89*) WLAN="$dev";; esac
  done
  [ -z "$WLAN" ] && WLAN=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
fi
# fallback: scan /sys for a wireless netdev
if [ -z "$WLAN" ]; then
  for n in /sys/class/net/*; do [ -d "$n/wireless" ] && WLAN=$(basename "$n") && break; done
fi
echo "  WiFi interface under test: ${WLAN:-<none found>}"
if [ -z "$WLAN" ]; then no "No wlan interface — dongle did not enumerate as WiFi. Stopping."; exit 2; fi

# --- 3. PATH A: raw CSI export (the heartrate-grade signal) -------------------
echo; echo "## 3. PATH A — raw CSI export (needed for HEARTRATE/breathing)"
mountpoint -q /sys/kernel/debug 2>/dev/null || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
PHY="phy0"; have iw && PHY=$(iw dev "$WLAN" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
DBG="/sys/kernel/debug/ieee80211/${PHY}/rtw89"
if [ -d "$DBG" ]; then
  echo "  rtw89 debugfs nodes ($DBG):"; ls -1 "$DBG" 2>/dev/null | sed 's/^/    /'
  if ls "$DBG" 2>/dev/null | grep -qiE 'csi|phy_sts|chan_info|beamform'; then
    CSI_OK=1; warn "Found a possibly-CSI-related node — inspect manually (could change the verdict!)."
  else no "No CSI / channel-info node (expected — Realtek doesn't export CSI)."; fi
else
  no "No rtw89 debugfs dir at $DBG — no CSI interface exposed."
fi
echo "  => Raw per-packet CSI from this chip via mainline rtw89: not available."

# --- 4. PATH B: monitor mode -> beamforming feedback (RuView BFLD, presence) --
echo; echo "## 4. PATH B — monitor mode + BFI sniffing (RuView BFLD: presence/motion only)"
if ! have iw; then
  no "iw missing — cannot test monitor mode. (PATH B unresolved.)"
else
  MODES=$(iw phy "$PHY" info 2>/dev/null | sed -n '/Supported interface modes/,/Band /p')
  echo "$MODES" | grep -E '\*[[:space:]]' | sed 's/^/    /'
  if echo "$MODES" | grep -qiE '\*[[:space:]]*monitor'; then
    ok "Chip ADVERTISES monitor mode. Trying to actually enter it..."
    ip link set "$WLAN" down 2>/dev/null
    if iw dev "$WLAN" set type monitor 2>/tmp/mon.err && ip link set "$WLAN" up 2>/dev/null; then
      TYPE=$(iw dev "$WLAN" info 2>/dev/null | awk '/type/{print $2}')
      if [ "$TYPE" = "monitor" ]; then MONITOR_OK=1; ok "Now in MONITOR mode — BFI/BFLD path is viable on this dongle."
      else warn "set type monitor returned but type=$TYPE"; fi
    else
      no "Kernel REFUSED monitor mode: $(cat /tmp/mon.err 2>/dev/null). BFI path dead on this dongle."
    fi
  else
    no "Chip does NOT advertise monitor mode under rtw89 -> BFI/BFLD path unavailable."
  fi
fi

# --- 5. optional BFI capture --------------------------------------------------
if [ "$MONITOR_OK" = 1 ] && [ "$CAPTURE" = 1 ] && have tcpdump; then
  echo; echo "## 5. 20s capture — 802.11ac/ax compressed beamforming action frames"
  echo "     (Needs an AP + active client doing beamforming nearby; set channel to the AP's.)"
  iw dev "$WLAN" set channel 36 80MHz 2>/dev/null || iw dev "$WLAN" set channel 6 2>/dev/null || true
  timeout 20 tcpdump -i "$WLAN" -nn -c 200 'type mgt subtype action or type mgt subtype action-ack' \
      -w /tmp/bfi.pcap 2>/dev/null
  BFI_FRAMES=$(tcpdump -r /tmp/bfi.pcap 2>/dev/null | wc -l | tr -d ' ')
  echo "  Captured $BFI_FRAMES action frames -> /tmp/bfi.pcap"
  echo "  Inspect in Wireshark:  wlan.vht.action or wlan.he_action  (compressed beamforming)"
fi

# restore managed mode
if have iw; then
  ip link set "$WLAN" down 2>/dev/null; iw dev "$WLAN" set type managed 2>/dev/null
  ip link set "$WLAN" up 2>/dev/null
fi

# --- 6. verdict ---------------------------------------------------------------
echo; echo "$LINE"; echo " VERDICT for ${CHIP} (${WLAN})"; echo "$LINE"
if [ "$CSI_OK" = 1 ]; then
  echo -e "  ${P}HEARTRATE: investigate${O} — a CSI-ish debugfs node exists (unexpected!)."
  echo    "             Inspect $DBG and try wiring it to RuView's HeartRateExtractor."
else
  echo -e "  ${F}HEARTRATE: NOT possible via this dongle${O} — no raw CSI from rtw89."
  echo    "             Use ESP32-S3 (USB serial) or ESP32-C6 + MR60BHA2 mmWave instead."
fi
if [ "$MONITOR_OK" = 1 ]; then
  echo -e "  ${W}PRESENCE/MOTION: plausible${O} — monitor mode works, so RuView BFLD (BFI"
  echo    "             sniffing) can run. Needs beamforming traffic in the room. No vitals."
else
  echo -e "  ${F}PRESENCE via BFI: NOT available${O} — this dongle won't do monitor mode here."
fi
echo "$LINE"
echo "  Bottom line: for HEARTRATE this dongle is the wrong tool on any OS."
echo "  Best path on the RK3308: ESP32-C6 + MR60BHA2 (mmWave) or ESP32-S3 (CSI) over USB -> RuView."
echo
echo "  >> Paste this whole output back to continue."
