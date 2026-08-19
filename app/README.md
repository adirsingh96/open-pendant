# OpenPendant Flutter app

Host for the necklace: arm once → BLE PCM chunks → local VAD → OpenAI → SQLite sessions with wall-clock segments.

## Setup

```bash
cd app
flutter pub get
flutter run -d macos
```

On a phone, use a physical device (BLE does not work in the iOS simulator):

```bash
flutter devices
flutter run
```

Paste the OpenAI API key in **Settings**. Never put it in firmware.

Disconnect nRF Connect first (the pendant allows one BLE connection).

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

Android `AndroidManifest.xml`:

- `BLUETOOTH`, `BLUETOOTH_ADMIN`, `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION` (pre-12)

## Consent and armed capture

**Record** = arm: GATT notify on, LED solid, one session id. Capture keeps running until **Stop** or **Sleep**.

Chunks rotate on IMU sleep, ~30 s of raw buffer, or quiet after speech. Each chunk is VAD-gated; silence is not sent to OpenAI. Home stitches session text and shows STT spend.

## Mic calibrate

**Calibrate** (home): wear the pendant as you will all day, read the script. The host measures speech-band energy at your mouth–mic distance and sets a personal VAD energy floor (saved on this computer). Re-calibrate if how you wear it changes.

## Voices (speaker names)

**Voices**: enroll up to 4 people (2–10 s sample + name). When voices exist, chunks use `gpt-4o-transcribe-diarize` with those references. Otherwise `gpt-transcribe` (Hindi + English hints; Devanagari for Hindi). Fallback: `gpt-4o-mini-transcribe`.

## IMU sleep debug

After flashing firmware that includes status UUID `70301103-…`, Connect (Record is not required). The **Debug** card shows IMU SLEEP/AWAKE, mic, still meter, battery/USB, and VAD calibrate status.

- Leave the board still ~10 s → IMU **SLEEP**, mic **stopped**.
- Pick it up → **AWAKE**. Mic noise does not block sleep.
- App **Sleep** is a BLE disconnect, not IMU sleep.
