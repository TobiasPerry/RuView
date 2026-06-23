# Can I do RuView presence + heart-rate sensing through a USB WiFi dongle on a Mac?

**Short answer: no — not through the dongle, and not on macOS at all.** But the
RuView *software* runs fine on this Mac, and there's a cheap, well-supported
hardware path to actually achieve the goal. Details below.

Investigated 2026-06-23 on an Apple Silicon Mac (macOS 15 / Darwin 25.5.0).

> **UPDATE (same day, after more info):** the user clarified (a) the dongle is a
> **driver-free Wi-Fi 6 "AX900" + BT 5.3** adapter — i.e. a Realtek **RTL8851BU**
> (`rtw89`), **not** an RTL88x2 as first guessed — and (b) it will actually be
> used on a **Rockchip RK3308 Linux** device (the "Ato" appliance), not the Mac.
> That changes the analysis: on Linux the dongle *does* work as a NIC, and there's
> a second sensing path (beamforming-feedback / BFLD) I'd initially overlooked.
> Full revised verdict in **§8** below; run **`test_dongle_csi.sh`** on the
> Rockchip to settle it empirically. Bottom line is unchanged for the stated
> goal: **heartrate through this dongle is still not feasible.**

---

## 1. What is actually plugged into the Mac

USB inventory (`ioreg -p IOUSB`):

| Device | Vendor:Product | What it really is |
|---|---|---|
| `SZNX LAN 100M` (Naxiang) | `0x35B5:0x3500` → `en8` | USB **wired Ethernet** adapter (100 Mbit) |
| `AX88179B` (ASIX) | `0x0B95:0x1790` → `en7` | USB **wired Ethernet** adapter (gigabit) |
| `2.4G Wireless Mouse` | `0x3938:0x1191` | A **mouse** receiver (HID), not WiFi |
| `DISK` (Realtek) | **`0x0BDA:0x1A2B`** | **The WiFi dongle** — a Realtek RTL88x2-family USB WiFi adapter, currently in **CD-ROM / "driver-disk" mode** |

So the thing you plugged in is almost certainly the **Realtek `0bda:1a2b`**. That
USB ID is the classic "install-disk" identity that Realtek 8812AU/8821AU-style
dongles present *before* a host driver mode-switches them into an actual WiFi
NIC. On this Mac it never switched — it shows up as a `DISK`, not a WiFi
interface, and it isn't mounted.

### Two strikes before we even get to CSI
1. **It isn't working as a WiFi adapter at all.** Apple Silicon macOS does not
   load third-party USB-WiFi kernel drivers (Realtek's installers are unsigned
   / broken on recent macOS). The only WiFi NIC the OS sees is the built-in
   `en0`. So the dongle can't even join a network here, let alone sense.
2. **Even if it worked, it can't emit CSI** (next section).

---

## 2. The real blocker: RuView needs CSI, which this setup can't produce

RuView doesn't sense from a normal WiFi *connection*. It needs **Channel State
Information (CSI)** — the raw per-subcarrier amplitude/phase of received WiFi
frames. Breathing and heart rate come from millimeter-scale chest motion
perturbing CSI phase/amplitude over time. Ordinary WiFi adapters throw CSI away;
you only get it from firmware/drivers specifically built to expose it.

Who can actually give you CSI:

| Path | CSI available? | Notes |
|---|---|---|
| **Any WiFi adapter on macOS** | ❌ **Never** | macOS exposes no CSI API for any chipset. The old Broadcom `wl`/debug path is gone on Apple Silicon. This is a hard dead-end regardless of dongle. |
| **This Realtek `0bda:1a2b` dongle, on Linux** | ⚠️ Marginal | Realtek CSI extraction exists only as fragile research forks for specific chip revisions; not what RuView targets. Not a realistic route. |
| **Intel 5300 / AX200-AX210, Atheros (ath9k), Broadcom (Nexmon), on Linux** | ✅ Yes | Mature CSI tools (Linux 802.11n CSI Tool, PicoScenes, Nexmon CSI). Requires Linux + that exact NIC. |
| **ESP32-S3 / ESP32-C6** | ✅ Yes — **this is what RuView is built for** | ~$6–9 board, streams CSI over USB serial. RuView's firmware + `examples/ruview_live.py` expect exactly this. |

**Conclusion:** the dongle is the wrong tool, and the Mac's OS rules out the
dongle route entirely. The supported path is an ESP32 feeding CSI to the Mac
over USB serial — the Mac then runs the RuView extractors (which, as shown
below, already work here).

---

## 3. What *does* work on this Mac — proof the software half is fine

`synthetic_vitals_demo.py` in this folder drives RuView's **real, compiled**
`BreathingExtractor` / `HeartRateExtractor` (the Rust-backed PyO3 wheel) with
**synthetic CSI** — a signal modeling a person breathing at 15 BPM with a 72 BPM
heartbeat. The extractors recover it:

```
Breathing : median 15.0 BPM  (truth 15.0, err 0.0)  conf=0.42  Degraded  [OK]
HeartRate : median 73.2 BPM  (truth 72.0, err 1.2)  conf=0.53  Degraded  [OK]
```

Run it yourself:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install "wifi-densepose==2.0.0a1"        # see packaging caveat below
python examples/mac-dongle/synthetic_vitals_demo.py
```

This proves: install the package, feed it CSI frames, get vitals. The ONLY thing
the demo fakes is the CSI source — which on a real rig is the ESP32.

### Packaging caveat (worth knowing)
The README's "Option 4: `pip install ruview` / `wifi-densepose`" is **partly
broken** as published:
- `pip install ruview` → **package does not exist on PyPI.**
- `pip install wifi-densepose` → installs a **v1.x stub that immediately raises
  `ImportError`** telling you to `pip install wifi-densepose==2.0.0` …
- … but **`2.0.0` was never published.** Only **`2.0.0a1`** (an alpha) exists,
  and that one *does* work and ships the real extractors. The demo pins it.

---

## 4. Realistic path to actually achieve the goal

To get genuine presence + breathing + heart rate:

1. **Buy an ESP32-S3 dev board** (~$9; ESP32-C6 also supported). This is RuView's
   intended, documented sensor.
2. **Flash the CSI-node firmware** in `firmware/esp32-csi-node/` (uses `esptool`
   / ESP-IDF — neither is installed here yet; `pip install esptool` + ESP-IDF).
3. **Plug it into the Mac** — it appears as a USB serial port (`/dev/cu.usbserial-*`).
4. **Run the live pipeline:** `python examples/ruview_live.py --csi /dev/cu.usbserial-XXXX`.
   The board streams CSI; the Mac runs the same extractors validated above.
5. For best vitals, place the ESP32 ~0.5–2 m from a seated/lying person; a second
   WiFi device (or the board's own AP) acts as the RF illuminator.

If you specifically want to use a **USB dongle** for sensing, you'd need to move
off macOS: a Linux machine + a CSI-capable NIC (Intel AX210, or an Atheros/
Nexmon-supported chip) + a CSI tool like PicoScenes. That's a heavier lift than
the $9 ESP32 and is not what RuView's pipeline is wired for.

---

## 5. A note on RuView's claims

RuView's signal-processing core is legitimate and based on real WiFi-sensing
research (bandpass 0.1–0.5 Hz for respiration, 0.8–2.0 Hz for heart rate, on CSI
amplitude residuals — exactly what we exercised above). But the repo's marketing
is heavy and some headline numbers were self-retracted (e.g. the old "100%
presence accuracy" → honest 82.3%). Treat "see through walls" / accuracy badges
with skepticism; treat the extractor code as a solid, runnable foundation.

---

### TL;DR
- The dongle (Realtek `0bda:1a2b`) can't do this — no CSI, and it doesn't even
  work as WiFi on Apple Silicon macOS. macOS gives no CSI from *any* adapter.
- RuView's vitals extractors **run on this Mac today** (proven with synthetic CSI).
- To make it real: add a **~$9 ESP32-S3** as the CSI source over USB serial.

---

## 8. UPDATE — corrected chip (RTL8851BU/AX900), the Rockchip, and the BFI path

**The dongle:** a "driver-free Wi-Fi 6 AX900 + BT 5.3" adapter = Realtek
**RTL8851BU** (1×1 802.11ax + BT 5.3), driven by **`rtw89`**. The `0bda:1a2b` ID
is its CD-ROM/driver-disk mode; `usb_modeswitch -KW -v 0bda -p 1a2b` flips it to a
WiFi NIC. (TP-Link's "AX900" adapter is the same RTL8851BU.)

**The host:** Rockchip **RK3308** Linux appliance (Yocto / `meta-ato`, kernel
6.12). Its build already ships `rtl8851bu-firmware` + `rtw89` modules, so the
dongle comes up as a normal NIC there (it couldn't on macOS).

### Calibrated verdict (the honest confidence breakdown)

| Capability | Via this dongle? | Confidence | Why |
|---|---|---|---|
| **Heartrate / breathing** | **No** | ~85% | Needs raw per-packet CSI. `rtw89` exposes none; Realtek never shipped a CSI tool; no community patch exists. The one CSI-free workaround (BFI, below) doesn't reach heartrate. |
| Raw CSI as a client (ESP32-grade) | No | ~90% | Driver/firmware wall, not physics. |
| **Presence / motion** | **Maybe** | ~40–55% | Possible via **BFI** — *if* `rtw89` gives this chip monitor mode (historically weak for rtw89). |

### The BFI / BFLD path (the nuance the original §2 missed)

**Beamforming Feedback Information (BFI):** 802.11ac/ax clients send *compressed
beamforming reports* to the AP in **plaintext action frames**. Any card in
**monitor mode** can sniff them — no CSI firmware required. RuView ships exactly
this as the **`wifi-densepose-bfld`** crate (ADR-118): it ingests BFI and emits
`presence` / `motion` / `person_count` / `zone_activity` (MQTT `…/bfld/presence`,
HA entities). **Note what's absent: no breathing, no heartrate** — BFI is low-rate
and heavily quantized, so it's a presence/motion layer by design. Even RuView's
own BFI path does not claim vitals.

Two gates remain for using *this* dongle even for presence:
1. `rtw89` must actually grant the RTL8851BU **monitor mode** (unconfirmed; rtw89
   monitor support is patchy — the solid monitor-mode Realtek chips are the older
   RTL8812AU on the aircrack-ng fork, not the Wi-Fi-6 ones).
2. There must be 802.11ac/ax **beamforming traffic** in the room to sniff.

Run **`test_dongle_csi.sh`** (this folder) on the Rockchip — it mode-switches,
checks for a CSI debugfs node (Path A) and for working monitor mode (Path B), and
prints a hardware-derived verdict instead of these probabilities.

### What RuView itself supports (authoritative — from the repo's `CLAUDE.md`)

RuView's **Supported Hardware** table lists **no USB WiFi dongle**. Its sanctioned
sensors are:

| Device | Role | Cost |
|---|---|---|
| **ESP32-S3** | WiFi CSI sensing node | ~$9 |
| **ESP32-C6 + Seeed MR60BHA2** | **mmWave HR/BR/presence** + WiFi CSI | ~$15 |
| HLK-LD2410 | 24 GHz presence + distance | ~$3 |

And rvCSI's only *real*-CSI adapter is **Nexmon on Broadcom (BCM43455, Raspberry
Pi)** — again, not a Realtek USB dongle.

### Recommendation for the Ato RK3308 (since heartrate is essential)
The dongle stays as the device's **network** link. For **vitals**, add a dedicated
sensor over UART/USB that does its own DSP (keeping the weak RK3308 idle):
- **ESP32-C6 + MR60BHA2 (60 GHz mmWave), ~$15** — best heartrate/breathing
  reliability for a shipping elder-care product; RuView lists it explicitly.
- **ESP32-S3 (WiFi CSI), ~$9** — RuView's native path; cheaper; noisier vitals.

Either streams `presence/BR/HR` that `ato-device` forwards to `ato-server`,
fitting the existing polling architecture with ~zero added CPU load.
