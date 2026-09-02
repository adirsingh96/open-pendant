# OpenPendant

Open-source DIY AI audio pendant. Firmware is Zephyr on a Seeed XIAO nRF52840 Sense. Capture happens on the necklace; speech-to-text runs on the **phone** (OpenAI Audio API) or laptop. The MCU never holds an API key.

## Mission
People should be able to build their own pendant from a short BOM, flash UF2, and run a documented BLE audio protocol. Closed products (Humane Pin, Limitless) showed what happens when the cloud goes away. STT is a **host plugin** (OpenAI today, local Whisper still available on the laptop).

## Hardware
*   **MCU:** Seeed Studio XIAO nRF52840 Sense (Nordic nRF52840, Cortex-M4F)
*   **Mic:** Onboard PDM MEMS (Knowles SPU0410LR5H-QB)
*   **IMU:** LSM6DS3TR-C. Firmware sleeps the PDM mic when the board is **still** (~10 s), wakes on motion. Mic noise is ignored here; the host VAD drops non-speech before STT. Not a consent signal — notify + LED still mean recording.
*   **Power:** WLY602030 3.7 V 300 mAh 1S LiPo on BAT+/BAT−. USB-C charges via BQ25101. Voltage-based SoC on GATT status (not a coulomb counter).
*   **Form factor:** Wearable pendant (3D-printed shell later)

## Software stack
*   **OS:** Zephyr RTOS (nRF Connect SDK v3.4.0 / Zephyr v4.4.0)
*   **Build:** CMake / West / Sysbuild
*   **Language:** C (Zephyr APIs only — no Arduino)
*   **Phone:** Flutter app in [`app/`](app/) — armed BLE PCM → local VAD → OpenAI → SQLite sessions
*   **Laptop tools:** Python (`bleak`, OpenAI API or local Whisper)

## Validated state
*   UF2 flash: double-tap RESET → `XIAO-SENSE` → `dd` the `zephyr.uf2` if Finder copy fails.
*   BLE advertises as **OpenPendant** (after this firmware is flashed; older images used `AI Pendant`).
*   Serial: `python3 -m serial.tools.miniterm /dev/cu.usbmodem1101 115200` (macOS `screen` often hangs up CDC).
*   GATT PCM notify works: `notify=1`, `drop=0`.
*   8 s BLE capture: 250 complete 1024-byte chunks, 0 seq gaps, RMS ~3200 on speech. Laptop `small.en` was usable; OpenAI is the accuracy path.
*   Nordic SoftDevice Controller only. Do **not** enable `CONFIG_BT_LL_SW_SPLIT` on this board (USB CDC breaks).

## GATT protocol (stable)
*   **Service UUID:** `70301101-4a1b-4c8d-9e0f-a1b2c3d4e5f6`
*   **PCM Notify UUID:** `70301102-4a1b-4c8d-9e0f-a1b2c3d4e5f6`
*   **Notify payload:** 4-byte header + PCM fragment
    *   bytes 0–1: little-endian chunk sequence
    *   byte 2: fragment index
    *   byte 3: fragment count
    *   bytes 4+: 16 kHz / 16-bit little-endian mono PCM
*   **Status UUID:** `70301103-4a1b-4c8d-9e0f-a1b2c3d4e5f6` (READ/NOTIFY)
    *   byte 0: flags (`1` IMU sleep, `2` mic running, `4` IMU ready, `8` last accel fetch ok, `16` USB VBUS)
    *   bytes 1–2: LE volume
    *   byte 3: consecutive still polls (sleep at 10)
    *   bytes 4–5: LE battery millivolts (0 = no reading). App maps 3.30–4.20 V to ~0–100% **only when USB is unplugged** (charger rail is ~4.1 V with no cell).
*   **Consent:** enabling Notify is recording. The red LED stays on while notify is enabled.

## Transcription pipeline (host)
**Record** arms notify once. Chunks rotate on IMU sleep, ~30 s raw, or quiet after speech. Local spectral VAD must see enough speech before STT. Meetings use a fixed energy floor (`1e9`, 0.5 s min); notes use the optional wearer-calibrated floor. Text is stitched by `session_id` + `seq`. WAV files are deleted after STT.

*   **STT:** Saaras v4 for words. Optional OpenAI `gpt-4o-transcribe-diarize` for who spoke (Settings toggle; People samples as references). Keys on the phone only.
*   **clips:** `id`, `started_at`, `duration_s`, `full_text`, `wav_path`, `stt_model`, `status`, `session_id`, `seq`, billed/removed seconds, tokens, `cost_usd`
*   **segments:** `start_s`, `end_s`, `spoken_at`, `text`, `speaker`
*   Later sync (not built): [docs/sync_api.md](docs/sync_api.md)

Laptop A/B:

```text
export OPENAI_API_KEY=
python3 tools/capture_pcm.py --seconds 8 --out capture.wav && \
  python3 tools/transcribe.py capture.wav --backend openai
```

## Later (not now)
*   Sync backend, Q&A over clips, Mem0
*   Opus/ADPCM on-device
*   Always-on capture without arm, IMU tap / wear gate, hardware button
*   Companion / live assistant

## OSS notes
*   **BOM:** XIAO nRF52840 Sense + optional 1S LiPo + USB-C cable
*   **License:** Apache-2.0
*   Record only with an obvious LED and an explicit host subscribe.

## AI assistant guidelines
*   Zephyr RTOS C APIs (v4.4.0+), not Arduino.
*   Logging: `printk` / `LOG_INF`. Buffers: slabs / message queues.
*   Public repo: do not commit API keys, local WAVs under `app/`, or `~/.config` secrets.
*   Do not enable `CONFIG_BT_LL_SW_SPLIT` on this board.
