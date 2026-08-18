#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! command -v flutter >/dev/null 2>&1; then
  echo "Install Flutter, then re-run: https://docs.flutter.dev/get-started/install"
  exit 1
fi
flutter create . --project-name openpendant --org com.openpendant --platforms ios,android
python3 "$(dirname "$0")/patch_native.py"
flutter pub get
echo "OK. Set the API key in the app Settings screen, then: flutter run"
