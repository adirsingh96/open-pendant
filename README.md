# OpenPendant

Open-source DIY AI audio pendant. Firmware runs on a **Seeed XIAO nRF52840 Sense**. The necklace captures audio and streams 16 kHz PCM over BLE. Speech-to-text runs on the **phone or laptop**. The MCU never holds an API key.

Record only with an obvious LED and an explicit host subscribe (GATT notify on = recording).

## Hardware

| Part | Notes |
|------|--------|
| Seeed XIAO nRF52840 Sense | nRF52840 + onboard PDM mic + LSM6DS3TR-C IMU |
| microSD SPI/SDIO module | 8-pin breakout; VCC = **3V3 only** (never 5V) |
| Ø6 tactile button | 2-pin NO; COM → GND, NO → D1 |
| 22 µF capacitor | Across SD **3V3** and **GND** (16 V ceramic preferred) |
| Perfboard strip | ~8 × 18 holes; XIAO + SD on the front, LiPo on the back |
| WLY602030 1S LiPo | 3.7 V nominal, 300 mAh, 6 × 20 × 30 mm. Open-wire to **BAT+/BAT−**. USB-C charges via BQ25101. |
| USB-C cable | Dev and UF2 flash |

The table above is the first bench build on perfboard. The wearable replaces that strip and the SD breakout with the carrier below. Do not order the older 30 × 45 mm board.

| Build file | What it is |
|------------|------------|
| [`openpendant_carrier-gerbers.zip`](hardware/openpendant_carrier/openpendant_carrier/output/openpendant_carrier-gerbers.zip) | JLCPCB gerbers. Bare boards, 2-layer, 1.6 mm, 1 oz, lead-free HASL. Assembly off. |
| [`openpendant_carrier.kicad_pro`](hardware/openpendant_carrier/openpendant_carrier/openpendant_carrier.kicad_pro) | KiCad source |
| [`docs/carrier_assembly.html`](docs/carrier_assembly.html) | What arrives, what you solder, and the pin map |
| [`cad/character/`](hardware/openpendant_carrier/cad/character/) | Case to print: `character_front.3mf`, `character_back.stl`, `character_button_hat.stl`. Read `PRINT.txt` in that folder. |

Print the character case (Orbit O). PETG, 0.4 mm nozzle, 0.2 mm layers, no supports. Front skirt on the bed. Back chest-down so the chain bail sits on the bed. Do not print anything from `cad/print/`; those shells are an older shape.

Assembly guide for the first perfboard build: [`docs/pendant_assembly.html`](docs/pendant_assembly.html).

### Wiring (USB at the bottom)

Pin map with the component face toward you:

```text
  XIAO                              microSD (SPI)
  ----                              -------------
  D9  (SCK)  ---------------------> CLK
  D8  (MOSI) ---------------------> CMD
  D7  (MISO) ---------------------> D0
  D6  (CS)   ---------------------> D3
  3V3 ----------------------------> 3V3
  GND ----------------------------> GND
                                    D1, D2  (leave open)

  Button NO  ---------------------> D1
  Button COM ---------------------> GND

  22 µF  across SD 3V3 ↔ SD GND

  LiPo red  --> BAT+     (through the BAT window, last)
  LiPo black -> BAT−
```

```text
Left (USB bottom)       Right (USB bottom)
─────────────────       ──────────────────
D6 ──► SD D3 (CS)       D7 ──► SD D0
D5  (IMU SCL — open)    D8 ──► SD CMD
D4  (IMU SDA — open)    D9 ──► SD CLK
D3                      D10
D2                      3V3 ──► SD 3V3
D1  button NO           GND
D0                      5V   (empty)
```

Firmware remaps SPI2 onto **D9 / D8 / D7** (not the board silk SPI defaults D8 / D10 / D9) and disables UART0 so it cannot steal **D6 / D7**. After soldering, flash over USB (no cell required) and run **Settings → Developer → Run SD test** with a FAT32 card.

## What you get

- **Firmware** (Zephyr / nRF Connect SDK 3.4, Zephyr 4.4): BLE GATT PCM + status, IMU still-sleep (mic off when the board is still, wake on motion), battery voltage / SoC estimate, microSD FAT R/W self-test, **offline meeting/note PCM on SD** with BLE sync (`70301105`).
- **Flutter app** in [`app/`](app/): meetings and hold-to-talk notes over BLE, local VAD, **Saaras v4** or on-device **Qwen3-ASR**, reminders, daily briefings and recaps, persistent follow-ups, Memories search, local SQLite, and **pull of offline SD clips on reconnect**. Meetings stay one transcript. Speaker diarization is not applied.
- **Laptop tools** in [`tools/`](tools/): BLE capture to WAV, OpenAI or local Whisper.

Protocol, clip schema, and roadmap: [project_context.md](project_context.md). Later sync sketch: [docs/sync_api.md](docs/sync_api.md).

## Firmware

Requires [nRF Connect SDK v3.4.0](https://docs.nordicsemi.com/bundle/ncs-latest/page/nrf/installation.html). Use the Nordic SoftDevice Controller only — do **not** enable `CONFIG_BT_LL_SW_SPLIT` on this board (USB CDC breaks).

```bash
west build -b xiao_ble/nrf52840/sense -d build .
```

Double-tap RESET so the volume `XIAO-SENSE` appears. Finder copy often fails; `dd` works:

```bash
dd if=$(find build -name zephyr.uf2 | head -1) of=/Volumes/XIAO-SENSE/CURRENT.UF2 bs=4096
```

Serial (macOS `screen` often hangs up CDC):

```bash
python3 -m serial.tools.miniterm /dev/cu.usbmodem1101 115200
```

BLE advertises as **OpenPendant**. Disconnect nRF Connect before the app or laptop capture (one connection).

**Control** UUID `70301104-…`:
- `0` / `1` — find-pendant LED flash off / on
- `2` — SD mount / write / read self-test (result in status bytes 8–9)
- `0x10` — list next pending offline clip (response on SD data notify)
- `0x11` + `id[8]` — open clip for read
- `0x12` + `offset_le32` + `len_le16` — read chunk
- `0x13` + `id[8]` — delete after phone has stored the clip

**SD data** UUID `70301105-…` (NOTIFY/READ): list/read framing for offline sync. Live PCM stays on `70301102`.

**Offline button UX** (when PCM notify is off): single click toggles a meeting session under `/SD:/op/m_…/`; long-press records a note `n_….pcm`. When the phone arms live PCM, offline capture stops (no dual-write).

### Offline → sync test (USB power, no LiPo)

1. FAT32 card in the SPI slot; flash firmware; leave BLE disconnected (or never connect).
2. Offline: click → talk → click (meeting); long-press a note. Red LED while meeting armed; blue while note held.
3. Connect the app → automatic sync (or **Developer → Sync SD**). Meetings/notes appear and transcribe like live captures.
4. Second sync imports nothing (deleted on card / `pendant_clip_id` dedup).
5. Regression: with BLE connected and Record armed, audio streams over PCM notify with **no** new SD writes.
## Flutter app

```bash
cd app
flutter pub get
flutter run -d macos          # BLE works on Mac
# or a physical iPhone / Android — not the iOS simulator
```

Paste a **Sarvam** key in **Settings** (required for cloud transcripts) and an **OpenAI** key for day Clean, Memories, and meeting Recap. Keys stay on the host (Keychain / Keystore / app-support file on desktop), never on the pendant.

**Typical day**

1. Connect. Optional **Calibrate** (wear as usual, read the script) sets a personal VAD floor for **notes** only.
2. Optional **Voices**: enroll up to 4 people (2–10 s sample each). Meetings do not split one clip into speaker turns.
3. Start a **meeting** (pendant click, or **Start meeting** in the app) or take a **note** (hold the pendant ~0.7 s, or **Take a note** on the phone). Say “remind me to … at 10 AM” and the phone notifies 15 minutes before; notes without a time come back in an 8 AM reminder until you check them off. **Double-click** rings the connected phone so you can find it. **Find pendant** (connected sheet or Settings → More) is closer/farther from BLE signal, not a compass. Notify stays on while a meeting is armed; LED stays solid. Chunks rotate on IMU sleep, about 12 s of audio, or quiet after speech. Local VAD skips the cloud when there is no speech. Meetings use a fixed energy floor (`1e9`, ~0.5 s of speech) so people a metre or two from the chest mic still pass; hiss still has to look like voice. Wearer calibrate does not raise that meeting gate. Double-click a meeting title to rename it.
4. **Transcription:** Settings can use **Saaras v4** (cloud) or **on-device Qwen3-ASR**. Both store the engine text as returned (Hindi in Devanagari when that is what came back). Stop the meeting when you are done. Home groups chunks into one transcript. The transcript tab shows **Transcribing…** until STT catches up.
5. **Close the day:** Home surfaces pending notes and open loops. Tap **Close today** to clean the day’s stored text and create chapters, decisions, follow-ups, and a Memories-ready recap. Follow-ups become checkable notes and join the 8 AM digest until completed. Open the saved review and use **Refresh recap** to replace it after recording more; each run uses OpenAI.

More setup (permissions, IMU debug): [app/README.md](app/README.md).

## Laptop capture

```bash
python3 -m pip install -r tools/requirements.txt
export OPENAI_API_KEY=          # optional; omit for local Whisper
python3 tools/capture_pcm.py --seconds 8 --out capture.wav && \
  python3 tools/transcribe.py capture.wav --backend openai
```

Local Whisper:

```bash
python3 tools/transcribe.py capture.wav --backend local
```

## Consent and sleep

- **Recording:** enable PCM notify. The red LED stays solid while subscribed (armed).
- **IMU sleep:** after ~10 s still, firmware stops the PDM mic and PCM. BLE stays up. Motion wakes the mic. Host VAD drops non-speech before STT.
- **App Sleep** is a BLE disconnect, not IMU sleep.

## Battery

Solder the WLY602030 **red** lead to **BAT+** and **black** to **BAT−** (polarity matters; open wire, no JST). USB-C charges the cell through the XIAO BQ25101. Connect the cell **last**, after the SD / button joints meter clean on USB.

The cell has no fuel-gauge IC. Firmware measures pack voltage (P0.31, 1 MΩ / 510 kΩ divider) and the app maps that to a **rough SoC only when USB is unplugged**. On USB the BQ25101 rail reads ~4.1 V even with no cell, so the UI shows **USB** instead of a fake percent. Treat ~20% as “charge soon.” Keep P0.14 low whenever a cell is attached (firmware hog does this) so P0.31 stays within 3.6 V.

## License

[Apache License 2.0](LICENSE).
