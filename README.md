# OpenPendant

Open-source DIY AI audio pendant. Firmware runs on a **Seeed XIAO nRF52840 Sense**. The necklace captures audio and streams 16 kHz PCM over BLE. Speech-to-text runs on the **phone or laptop**. The MCU never holds an API key.

Record only with an obvious LED and an explicit host subscribe (GATT notify on = recording).

## Hardware

| Part | Notes |
|------|--------|
| Seeed XIAO nRF52840 Sense | nRF52840 + onboard PDM mic + LSM6DS3TR-C IMU |
| Optional 1S LiPo | e.g. 3.7 V 300 mAh (WLY602030) |
| USB-C cable | Dev and UF2 flash |

## What you get

- **Firmware** (Zephyr / nRF Connect SDK 3.4, Zephyr 4.4): BLE GATT PCM + status, IMU still-sleep (mic off when the board is still, wake on motion).
- **Flutter app** in [`app/`](app/): scan/connect, record, VAD, OpenAI transcription, local SQLite clips.
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

- **Recording:** enable PCM notify. The red LED stays solid while subscribed.
- **IMU sleep:** after ~10 s still, firmware stops the PDM mic and PCM. BLE stays up. Motion wakes the mic. Host VAD drops quiet audio before STT.
- **App Sleep** is a BLE disconnect, not IMU sleep.

## License

[Apache License 2.0](LICENSE).

This project is a small XIAO Sense + documented BLE protocol. It is not a clone of larger stacks such as [Omi](https://github.com/BasedHardware/omi).
