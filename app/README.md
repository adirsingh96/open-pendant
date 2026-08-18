# OpenPendant Flutter app

Host for the necklace: BLE PCM → WAV → OpenAI transcriptions → SQLite clips with segment timestamps.

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

## Consent

Record = GATT notify on. The pendant LED stays lit while subscribed.

## IMU sleep debug

After flashing firmware that includes status UUID `70301103-…`, Connect (Record is not required). The **Debug** card shows IMU SLEEP/AWAKE, mic, still meter, and mic level.

- Leave the board still ~10 s → IMU **SLEEP**, mic **stopped**.
- Pick it up → **AWAKE**. Mic noise does not block sleep.
- App **Sleep** is a BLE disconnect, not IMU sleep.
