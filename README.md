# OpenPendant

Open-source DIY AI audio pendant. Firmware runs on a **Seeed XIAO nRF52840 Sense**. The necklace captures audio and streams 16 kHz PCM over BLE. Speech-to-text runs on the **phone or laptop**. The MCU never holds an API key.

Record only with an obvious LED and an explicit host subscribe (GATT notify on = recording).

## Hardware

| Part | Notes |
|------|--------|
| Seeed XIAO nRF52840 Sense | nRF52840 + onboard PDM mic + LSM6DS3TR-C IMU |
| WLY602030 1S LiPo | 3.7 V nominal, 300 mAh, 6 × 20 × 30 mm (32.5 mm with PCM). Open-wire leads to the XIAO **BAT+/BAT−** pads. USB-C charges via the onboard BQ25101. |
| USB-C cable | Dev and UF2 flash |

## What you get

- **Firmware** (Zephyr / nRF Connect SDK 3.4, Zephyr 4.4): BLE GATT PCM + status, IMU still-sleep (mic off when the board is still, wake on motion), battery voltage / SoC estimate.
- **Flutter app** in [`app/`](app/): arm once for all-day capture, local VAD (+ mic calibration), chunked OpenAI STT, optional speaker names, session transcripts, local SQLite.
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

## Flutter app

```bash
cd app
flutter pub get
flutter run -d macos          # BLE works on Mac
# or a physical iPhone / Android — not the iOS simulator
```

Paste `OPENAI_API_KEY` in **Settings**. It is stored on the host (Keychain / Keystore / app-support file on desktop), never on the pendant.

**Typical day**

1. Connect → optional **Calibrate** (wear as usual, read the script) so quiet neck-mic speech is not skipped.
2. Optional **Voices**: enroll up to 4 people (2–10 s sample each) for named speaker labels.
3. Tap **Record** once to arm. Notify stays on; LED stays solid. Chunks rotate on IMU sleep, ~30 s raw, or quiet after speech. Local VAD skips the cloud when there is no speech.
4. Tap **Stop** or **Sleep** to disarm. Home groups chunks into one session transcript; time-range filters and STT spend are on the home screen.

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

Solder the WLY602030 **red** lead to **BAT+** and **black** to **BAT−** (polarity matters; open wire, no JST). USB-C charges the cell through the XIAO BQ25101.

The cell has no fuel-gauge IC. Firmware measures pack voltage (P0.31, 1 MΩ / 510 kΩ divider) and the app maps that to a **rough SoC only when USB is unplugged**. On USB the BQ25101 rail reads ~4.1 V even with no cell, so the UI shows **USB** instead of a fake percent. Treat ~20% as “charge soon.” Keep P0.14 low whenever a cell is attached (firmware hog does this) so P0.31 stays within 3.6 V.

## License

[Apache License 2.0](LICENSE).
