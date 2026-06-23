#!/usr/bin/env python3
"""
Coarse presence / motion from a Realtek rtw89 dongle (RTL8851BU / "AX900") —
no monitor mode, no extra hardware, while STAYING ONLINE.

It polls the live Wi-Fi link's signal quality (rtw89 `phy_info` debugfs, or
`iw dev <if> station dump` as a portable fallback), tracks a calibrated quiet
baseline, and flags MOTION when short-term signal variance exceeds threshold.

HONEST SCOPE — this detects MOTION / coarse PRESENCE only. It is NOT breathing
or heart rate. This chip exposes no CSI (verified: rtw89 debugfs has no csi /
chan_info node), so heartbeat-grade sensing is impossible here. For vitals use
an ESP32-S3 (WiFi CSI) or ESP32-C6 + MR60BHA2 (mmWave). See FINDINGS.md.

Verified working on the Ato RK3308 (ato001) against a real RTL8851BU: a 20 s
poll showed RSSI raw range 9 / 5 dB, EVM range 9.5 — usable variance, link
stayed connected throughout.

Usage (run ON the Rockchip, dongle = wlan0):
    sudo python3 dongle_presence.py                  # rtw89 phy_info (richest)
    python3 dongle_presence.py --source iw           # portable, no sudo needed
    sudo python3 dongle_presence.py --calibrate 15   # 15 s empty-room baseline
"""
from __future__ import annotations
import argparse, collections, re, statistics, subprocess, sys, time


def read_phyinfo(phy: str):
    path = f"/sys/kernel/debug/ieee80211/{phy}/rtw89/phy_info"
    try:
        txt = open(path).read()
    except PermissionError:
        txt = subprocess.run(["sudo", "cat", path], capture_output=True, text=True).stdout
    except FileNotFoundError:
        return None
    m = re.search(r"RSSI:\s*-?\d+\s*dBm\s*\(raw=(\d+)", txt)
    e = re.search(r"EVM:\s*\[([\d.]+).*?SNR:\s*(\d+)", txt, re.S)
    if not m:
        return None
    return {"primary": float(m.group(1)),  # raw RSSI = finest-grained
            "evm": float(e.group(1)) if e else 0.0,
            "snr": float(e.group(2)) if e else 0.0}


def read_iw(iface: str):
    out = subprocess.run(["iw", "dev", iface, "station", "dump"],
                         capture_output=True, text=True).stdout
    m = re.search(r"signal:\s*(-?\d+)", out)
    if not m:
        return None
    return {"primary": float(m.group(1)), "evm": 0.0, "snr": 0.0}


def sampler(args):
    if args.source == "iw":
        return lambda: read_iw(args.iface)
    if args.source == "phyinfo":
        return lambda: read_phyinfo(args.phy)
    # auto: prefer phy_info, fall back to iw
    if read_phyinfo(args.phy) is not None:
        return lambda: read_phyinfo(args.phy)
    return lambda: read_iw(args.iface)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--iface", default="wlan0")
    p.add_argument("--phy", default="phy0")
    p.add_argument("--source", choices=["auto", "phyinfo", "iw"], default="auto")
    p.add_argument("--rate", type=float, default=4.0, help="poll rate Hz")
    p.add_argument("--window", type=int, default=8, help="short-term window (samples)")
    p.add_argument("--calibrate", type=float, default=8.0, help="baseline seconds (keep area still)")
    p.add_argument("--k", type=float, default=3.0, help="motion threshold in baseline sigmas")
    p.add_argument("--duration", type=float, default=0.0, help="0 = run forever")
    a = p.parse_args()

    get = sampler(a)
    if get() is None:
        print(f"[!] No signal source. Is {a.iface} up and connected? "
              f"Try --source iw, or run with sudo for phy_info.", file=sys.stderr)
        return 2
    dt = 1.0 / a.rate

    # --- calibrate quiet baseline ---
    print(f"Calibrating baseline for {a.calibrate:.0f}s — keep the area still...")
    base = []
    t0 = time.time()
    while time.time() - t0 < a.calibrate:
        s = get()
        if s:
            base.append(s["primary"])
        time.sleep(dt)
    if len(base) < 3:
        print("[!] too few baseline samples", file=sys.stderr); return 2
    bmean = statistics.mean(base)
    bstd = max(statistics.pstdev(base), 0.5)   # floor so a dead-quiet link still has a scale
    print(f"  baseline: mean={bmean:.1f}  sigma={bstd:.2f}  (threshold = {a.k}σ = {a.k*bstd:.1f})")
    print("-" * 64)

    # --- detect ---
    win = collections.deque(maxlen=a.window)
    t0 = time.time()
    last_state = None
    while a.duration == 0.0 or time.time() - t0 < a.duration:
        s = get()
        if not s:
            time.sleep(dt); continue
        v = s["primary"]
        win.append(v)
        st = statistics.pstdev(win) if len(win) > 1 else 0.0
        dev = abs(v - bmean)
        energy = max(st, dev)                       # motion energy
        motion = energy > a.k * bstd
        score = min(1.0, energy / (a.k * bstd))
        bar = "#" * int(score * 20)
        state = "MOTION " if motion else "quiet  "
        if state != last_state:
            pass
        last_state = state
        sys.stdout.write(f"\r  {time.strftime('%H:%M:%S')}  sig={v:6.1f}  "
                         f"energy={energy:5.2f}  [{bar:<20}] {state}")
        sys.stdout.flush()
        time.sleep(dt)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
