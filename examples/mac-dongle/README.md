# RuView on a Mac + USB WiFi dongle — feasibility & working demo

This folder answers a concrete question: *"I plugged a USB WiFi dongle into my
Mac — can I use RuView to detect people's presence and heart rate through it?"*

- **`FINDINGS.md`** — the full answer. TL;DR: **not through the dongle, and not on
  macOS** (no Channel State Information is available from any WiFi adapter on
  macOS; the dongle doesn't even work as WiFi on Apple Silicon). But RuView's
  vitals software runs here, and a ~$9 ESP32-S3 is the real path.
- **`synthetic_vitals_demo.py`** — proof the software half works: drives RuView's
  *real compiled* `BreathingExtractor` / `HeartRateExtractor` with synthetic CSI
  and recovers an embedded breathing + heart rate. The only thing it fakes is
  the CSI source (which an ESP32 supplies in a real deployment).
- **`probe_dongle.sh`** — reusable macOS probe that inventories USB/WiFi state and
  prints the CSI-feasibility verdict for whatever dongle is attached.
- **`test_dongle_csi.sh`** — run ON a Linux host (e.g. the Rockchip): mode-switches
  the dongle, checks for a CSI debugfs node (heartrate path) and working monitor
  mode (BFI/presence path), prints a hardware-derived verdict.
- **`dongle_presence.py`** — a WORKING coarse presence/motion detector that uses the
  dongle's live RSSI/EVM (rtw89 `phy_info`) with no monitor mode and no extra
  hardware. Validated live on the Ato RK3308. Detects motion, NOT vitals.

## Quickstart

```bash
# from the repo root
python3 -m venv .venv && source .venv/bin/activate
pip install "wifi-densepose==2.0.0a1"      # the Rust-backed alpha (see FINDINGS.md §3)

python examples/mac-dongle/synthetic_vitals_demo.py            # default 15 BPM / 72 BPM
python examples/mac-dongle/synthetic_vitals_demo.py --br 12 --hr 60 --noise 0.1
bash    examples/mac-dongle/probe_dongle.sh                    # inspect your dongle
```

Expected demo output: breathing recovered ≈ ground truth, heart rate within
~1–2 BPM, both with non-trivial confidence — see `FINDINGS.md §3`.
