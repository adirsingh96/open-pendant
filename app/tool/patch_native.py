#!/usr/bin/env python3
"""Add BLE permission strings after `flutter create`."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

IOS_KEYS = """
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>OpenPendant uses Bluetooth to receive audio from the necklace.</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>OpenPendant uses Bluetooth to receive audio from the necklace.</string>
"""

ANDROID_PERMS = """
    <uses-permission android:name="android.permission.BLUETOOTH"/>
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN"/>
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
"""


def patch_plist(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "NSBluetoothAlwaysUsageDescription" in text:
        return
    text = text.replace("</dict>", IOS_KEYS + "</dict>", 1)
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")


def patch_manifest(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "BLUETOOTH_CONNECT" in text:
        return
    needle = "<manifest"
    idx = text.find(">")
    if idx < 0:
        raise SystemExit(f"bad manifest {path}")
    # insert after opening <manifest ...>
    end = text.find(">", text.find("<manifest")) + 1
    text = text[:end] + ANDROID_PERMS + text[end:]
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")


def patch_macos_entitlements(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "device.bluetooth" in text:
        return
    extra = """
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.device.bluetooth</key>
	<true/>
"""
    text = text.replace("</dict>", extra + "</dict>", 1)
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")


def main() -> None:
    plist = ROOT / "ios/Runner/Info.plist"
    manifest = ROOT / "android/app/src/main/AndroidManifest.xml"
    mac_plist = ROOT / "macos/Runner/Info.plist"
    if plist.exists():
        patch_plist(plist)
    else:
        print(f"skip missing {plist}")
    if mac_plist.exists():
        patch_plist(mac_plist)
    if manifest.exists():
        patch_manifest(manifest)
    else:
        print(f"skip missing {manifest}")
    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        p = ROOT / "macos/Runner" / name
        if p.exists():
            patch_macos_entitlements(p)


if __name__ == "__main__":
    main()
