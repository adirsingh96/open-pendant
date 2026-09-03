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
- **Flutter app** in [`app/`](app/): meetings and hold-to-talk notes over BLE, local VAD, **Saaras v4** or on-device **Qwen3-ASR**, optional **OpenAI diarization**, reminders, daily briefings and recaps, persistent follow-ups, Memories search, and local SQLite. Double-click the pendant to ring the connected phone.
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

Paste a **Sarvam** key in **Settings** (required for cloud transcripts) and an **OpenAI** key for diarization, day Clean, Memories, and meeting Recap. Keys stay on the host (Keychain / Keystore / app-support file on desktop), never on the pendant.

**Typical day**

1. Connect. Optional **Calibrate** (wear as usual, read the script) sets a personal VAD floor for **notes** only.
2. Optional **Voices**: enroll up to 4 people (2–10 s sample each) if you want named speakers. Turn **Diarization** on in Settings.
3. Start a **meeting** (pendant click, or **Start meeting** in the app) or take a **note** (hold the pendant ~0.7 s, or **Take a note** on the phone). Say “remind me to … at 10 AM” and the phone notifies 15 minutes before; notes without a time come back in an 8 AM reminder until you check them off. **Double-click** rings the connected phone so you can find it. **Find pendant** (connected sheet or Settings → More) is closer/farther from BLE signal, not a compass. Notify stays on while a meeting is armed; LED stays solid. Chunks rotate on IMU sleep, ~30 s raw, or quiet after speech. Local VAD skips the cloud when there is no speech. Meetings use a fixed energy floor (`1e9`, ~0.5 s of speech) so people a metre or two from the chest mic still pass; hiss still has to look like voice. Wearer calibrate does not raise that meeting gate. Double-click a meeting title to rename it.
4. **Transcription:** Settings can use **Saaras v4** (cloud) or **on-device Qwen3-ASR**. Both store the engine text as returned (Hindi in Devanagari when that is what came back). Diarization stays OpenAI and applies to Saaras meetings only. Stop the meeting when you are done. Home groups chunks into one transcript; with diarization on, a long Saaras phrase is split at OpenAI speaker-change times. The transcript tab shows **Transcribing…** until STT catches up.
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

Solder the WLY602030 **red** lead to **BAT+** and **black** to **BAT−** (polarity matters; open wire, no JST). USB-C charges the cell through the XIAO BQ25101.

The cell has no fuel-gauge IC. Firmware measures pack voltage (P0.31, 1 MΩ / 510 kΩ divider) and the app maps that to a **rough SoC only when USB is unplugged**. On USB the BQ25101 rail reads ~4.1 V even with no cell, so the UI shows **USB** instead of a fake percent. Treat ~20% as “charge soon.” Keep P0.14 low whenever a cell is attached (firmware hog does this) so P0.31 stays within 3.6 V.

## License

[Apache License 2.0](LICENSE).
