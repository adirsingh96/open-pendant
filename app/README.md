# OpenPendant Flutter app

Host for the necklace: arm once → BLE PCM chunks → local VAD → OpenAI → SQLite sessions with wall-clock segments.

## Setup

```bash
cd app
flutter pub get
flutter run -d macos
```

On a phone, use a physical device (BLE does not work in the iOS simulator). A **debug** build cannot be opened from the Home Screen; use `flutter build ios --release` (or profile) for that. If Xcode says the bundle ID `com.openpendant.openpendant` is taken, set a unique id under **Signing & Capabilities** for your Personal Team (do not commit that id).

```bash
flutter devices
flutter run
```

Paste API keys in **Settings**. **Sarvam** is required for cloud transcripts (Saaras v4). Or switch **Transcription** to **On-device** Qwen3-ASR 0.6B (~1 GB once). Transcripts are saved as the engine returns them. **OpenAI** is used for optional meeting diarization (Saaras path only), day Clean, Memories, and meeting Recap.

Disconnect nRF Connect first (the pendant allows one BLE connection). Optional **Auto-connect** in Settings → Behavior links the necklace when it is nearby and the app is open (off by default).

**Find phone:** double-click the pendant button while connected. The phone plays a looping tone (ignores the iOS silent switch) until you tap the screen, double-click again, or 40 seconds pass. Leave the app in the switcher; a force-quit will not receive the button.

**Find pendant:** from the connected sheet or Settings → More. Walk and watch the ring — a stronger BLE signal means closer. It cannot point a compass direction. Current firmware also flashes the board LEDs while you search.

**Note reminders:** “remind me to call mom at 10 AM” notifies 15 minutes before (or 5 minutes / at due if you are already close). Notes with no clock are included in an 8 AM digest until you check them off on the Notes tab. iOS will ask for notification permission the first time a reminder is scheduled.

**Daily review:** Home’s briefing surfaces the next pending note and unfinished work. **Close today** sends that day’s stored transcript text and notes to OpenAI, saves a structured recap, and promotes follow-ups/open loops into checkable notes. The recap feeds Memories and optionally Mem0. Open the day review and tap refresh to replace the recap after more recording; refreshing does not create recap copies, but it does use OpenAI again.

If `flutter run` fails with `failed to create ... /.config/flutter`, your `~/.config` may be owned by root:

```bash
sudo chown -R "$(whoami)" ~/.config
mkdir -p ~/.config/flutter
```

On macOS, Xcode must finish first-launch (missing `CoreSimulator` causes `xcodebuild` to fail):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
brew install cocoapods   # if Flutter reports CocoaPods missing
```

This app disables Swift Package Manager in `pubspec.yaml` because `flutter_secure_storage_macos` does not support it yet.

## Permissions

iOS `ios/Runner/Info.plist`:

- `NSBluetoothAlwaysUsageDescription` / `NSBluetoothPeripheralUsageDescription`
- `UIBackgroundModes`: `bluetooth-central` and `audio` so pendant buttons (including find-phone) and capture still work when the phone is locked (leave the app in the switcher; a force-quit will not wake)
- Local notifications: the first scheduled reminder prompts for alert permission. Timed notes and the morning digest still fire if the app is in the background.

Android `AndroidManifest.xml`:

- `BLUETOOTH`, `BLUETOOTH_ADMIN`, `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION` (pre-12)
- `POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED`, `SCHEDULE_EXACT_ALARM` for note reminders

## Consent and armed capture

**Record** = arm: GATT notify on, LED solid, one session id. Capture keeps running until **Stop** or **Sleep**.

Chunks rotate on IMU sleep, ~30 s of raw buffer, or quiet after speech. Each chunk is VAD-gated; silence is not sent to STT. After transcription succeeds or fails, clip WAV files are deleted. Home stitches session text and shows STT spend. While a clip is still in the STT queue, the meeting UI shows **Transcribing…** instead of an empty transcript.

**Meetings** use a fixed VAD energy floor (`VadGate.meetingEnergyFloor` = `1e9`) and at least **0.5 s** of speech-shaped audio. That is about 10× more sensitive than the note default (`1e10`), so quieter / farther talkers on the Knowles SPU0410 chest mic still reach STT. Spectral checks (speech-band ratio and centroid) still drop hiss and rumble. Wearer **Calibrate** does not change the meeting floor.

**Take a note** in the app is tap-to-start / tap-to-save. Pendant BLE still reports `noteHeld: false` while you are not holding the hardware button; those status packets must not stop an in-app note. Hold-to-talk on the necklace is unchanged.

## Mic calibrate

**Calibrate** (home): wear the pendant as you will all day, read the script. The host measures speech-band energy at your mouth–mic distance and sets a personal VAD energy floor for **notes** (saved on this device). Re-calibrate if how you wear it changes. Meetings ignore this floor.

## Voices (speaker names)

**Voices**: enroll up to 4 people (2–10 s sample + name). When **Diarization** is on, meeting clips go to `gpt-4o-transcribe-diarize` with those references; speaker labels are stamped onto the Saaras transcript by time, and a single long Saaras phrase is split at OpenAI speaker-change times. Notes stay on Saaras only (no speaker prefix in the note text).

## IMU sleep debug

After flashing firmware that includes status UUID `70301103-…`, Connect (Record is not required). The **Debug** card shows IMU SLEEP/AWAKE, mic, still meter, battery/USB, and VAD calibrate status.

- Leave the board still ~10 s → IMU **SLEEP**, mic **stopped**.
- Pick it up → **AWAKE**. Mic noise does not block sleep.
- App **Sleep** is a BLE disconnect, not IMU sleep.
