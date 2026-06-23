#!/usr/bin/env python3
"""
RuView vitals pipeline — synthetic-CSI demo (runs on a plain Mac, no hardware).

WHAT THIS PROVES
----------------
RuView's *real, compiled* vital-sign extractors (the Rust-backed
`BreathingExtractor` / `HeartRateExtractor` shipped in the `wifi-densepose`
PyO3 wheel) run fine on macOS. We feed them SYNTHETIC Channel State
Information (CSI) — a signal that mimics what an ESP32-S3 sensor would emit
when a person sits in front of it breathing and with a beating heart — and
the extractors recover the embedded breathing rate and heart rate.

WHAT IT DOES NOT PROVE
----------------------
That you can get this signal out of a USB WiFi dongle on a Mac. You can't —
see FINDINGS.md. The CSI here is generated in software. On a real deployment
the 56 numbers per frame come from an ESP32 over USB serial, NOT from the
Mac's WiFi adapter (macOS exposes no CSI, and the Realtek dongle has no CSI
firmware). This demo isolates the software half of the system so you can see
it work and build on it.

HOW THE SYNTHETIC CSI IS BUILT
------------------------------
A real person's chest/heart motion perturbs WiFi multipath, nudging each
subcarrier's amplitude up and down at the breathing (~0.25 Hz) and heart
(~1.2 Hz) frequencies. We model that as:

    residual_k(t) = gain_k * ( respiration(t) + heartbeat(t) ) + noise

where `residual` = amplitude minus its running mean (exactly the
"per-subcarrier amplitude residual" the real preprocessor feeds the
extractors). respiration() uses a few harmonics so it's peaked like real
breathing rather than a pure sine.

USAGE
-----
    python synthetic_vitals_demo.py                 # 15 BPM breathing, 72 BPM heart
    python synthetic_vitals_demo.py --br 12 --hr 60 # change the ground truth
    python synthetic_vitals_demo.py --noise 0.15    # harder (more sensor noise)

Requires:  pip install "wifi-densepose==2.0.0a1"   (the Rust-backed alpha)
"""
from __future__ import annotations

import argparse
import math
import random
import statistics
import sys
import time


def build_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--br", type=float, default=15.0, help="ground-truth breathing rate (BPM)")
    p.add_argument("--hr", type=float, default=72.0, help="ground-truth heart rate (BPM)")
    p.add_argument("--duration", type=float, default=55.0, help="seconds of CSI to synthesize")
    p.add_argument("--fs", type=float, default=100.0, help="CSI sample rate (Hz) — ESP32 default 100")
    p.add_argument("--subcarriers", type=int, default=56, help="subcarriers per frame (ESP32 default 56)")
    p.add_argument("--noise", type=float, default=0.05, help="per-subcarrier gaussian noise stddev")
    p.add_argument("--heart-amp", type=float, default=0.30, help="heartbeat amplitude relative to breathing")
    p.add_argument("--seed", type=int, default=7, help="RNG seed for reproducibility")
    p.add_argument("--no-live", action="store_true", help="disable the live ticking readout")
    return p.parse_args()


def main() -> int:
    a = build_args()

    try:
        import wifi_densepose as w
    except ImportError as e:
        print(f"[!] wifi_densepose import failed: {e}", file=sys.stderr)
        print('    Install the Rust-backed alpha:  pip install "wifi-densepose==2.0.0a1"', file=sys.stderr)
        return 2

    # The real, compiled extractors. esp32_default() == 56 subcarriers, 100 Hz,
    # 30 s window (breathing) / 15 s window (heart).
    if a.subcarriers == 56 and a.fs == 100.0:
        br_ext = w.BreathingExtractor.esp32_default()
        hr_ext = w.HeartRateExtractor.esp32_default()
    else:
        br_ext = w.BreathingExtractor(n_subcarriers=a.subcarriers, sample_rate=a.fs, window_secs=30.0)
        hr_ext = w.HeartRateExtractor(n_subcarriers=a.subcarriers, sample_rate=a.fs, window_secs=15.0)

    rng = random.Random(a.seed)
    # Each subcarrier couples to body motion differently (multipath geometry).
    gains = [0.5 + rng.random() for _ in range(a.subcarriers)]
    weights = [1.0] * a.subcarriers

    br_hz = a.br / 60.0
    hr_hz = a.hr / 60.0

    def respiration(t: float) -> float:
        # Peaked, non-sinusoidal — like a real chest wall (sharper inhale).
        return (math.sin(2 * math.pi * br_hz * t)
                + 0.40 * math.sin(4 * math.pi * br_hz * t)
                + 0.15 * math.sin(6 * math.pi * br_hz * t))

    def heartbeat(t: float) -> float:
        return a.heart_amp * math.sin(2 * math.pi * hr_hz * t)

    n_frames = int(a.duration * a.fs)
    print("=" * 64)
    print("RuView vitals — synthetic CSI demo (real compiled extractors)")
    print("=" * 64)
    print(f"  wifi_densepose {getattr(w, '__version__', '?')}  "
          f"features={getattr(w, '__build_features__', '?')}")
    print(f"  synthesizing {n_frames} frames = {a.duration:.0f}s @ {a.fs:.0f}Hz, "
          f"{a.subcarriers} subcarriers")
    print(f"  ground truth: breathing={a.br:.1f} BPM   heart={a.hr:.1f} BPM   noise σ={a.noise}")
    print("-" * 64)

    last_br = last_hr = None
    br_series: list[float] = []
    hr_series: list[float] = []
    tick = max(1, int(a.fs))  # ~1 readout per simulated second

    for i in range(n_frames):
        t = i / a.fs
        body = respiration(t) + heartbeat(t)
        residuals = [gains[k] * body + rng.gauss(0.0, a.noise) for k in range(a.subcarriers)]

        eb = br_ext.extract(residuals=residuals, weights=weights)
        eh = hr_ext.extract(residuals=residuals, weights=weights)
        if eb is not None:
            last_br = eb
            br_series.append(eb.value_bpm)
        if eh is not None:
            last_hr = eh
            hr_series.append(eh.value_bpm)

        if not a.no_live and i % tick == 0:
            bt = f"{last_br.value_bpm:5.1f}" if last_br else "  --"
            ht = f"{last_hr.value_bpm:5.1f}" if last_hr else "  --"
            warming = "  (warming up...)" if (last_br is None or last_hr is None) else "           "
            sys.stdout.write(f"\r  t={t:5.1f}s   breathing {bt} BPM   heart {ht} BPM{warming}")
            sys.stdout.flush()
            time.sleep(0.004)  # cosmetic, so it visibly "runs" — remove for batch use

    print("\n" + "-" * 64)

    def report(name: str, est, series: list[float], truth: float) -> bool:
        if est is None or not series:
            print(f"  {name:10s}: NO ESTIMATE (need a longer --duration to fill the window)")
            return False
        med = statistics.median(series)
        err = abs(med - truth)
        ok = err <= 2.0
        flag = "OK " if ok else "OFF"
        print(f"  {name:10s}: median {med:5.1f} BPM  (truth {truth:5.1f}, err {err:4.1f})  "
              f"last={est.value_bpm:5.1f}  conf={est.confidence:.2f}  {est.status}  [{flag}]")
        return ok

    print("  RESULT — RuView's extractors recovered the embedded vitals:")
    ok_br = report("Breathing", last_br, br_series, a.br)
    ok_hr = report("HeartRate", last_hr, hr_series, a.hr)
    print("=" * 64)
    if ok_br and ok_hr:
        print("  ✓ Pipeline works on this Mac. Missing piece for a real deployment:")
        print("    a CSI source (ESP32-S3 over USB serial). See FINDINGS.md.")
    return 0 if (ok_br and ok_hr) else 1


if __name__ == "__main__":
    raise SystemExit(main())
