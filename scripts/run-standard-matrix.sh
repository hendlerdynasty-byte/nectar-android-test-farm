#!/usr/bin/env bash
# One runner, one one-time bridge read; three sequential emulator profiles.
set -euo pipefail
: "${ARTIFACT_PATH:?}"
: "${PACKAGE:?}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
AAPT=$(find "$SDK/build-tools" -maxdepth 2 -name aapt -type f | sort -V | tail -1)
[ -x "$AAPT" ] || { echo 'aapt fehlt' >&2; exit 1; }
if [[ "$ARTIFACT_PATH" == *.aab ]]; then
  echo 'Standard-Matrix erfordert derzeit APK; Release-AAB separat testen' >&2
  exit 1
fi
BADGING=$("$AAPT" dump badging "$ARTIFACT_PATH")
MIN=$(sed -n "s/^sdkVersion:'\([0-9]*\)'.*/\1/p" <<< "$BADGING" | head -1)
TARGET=$(sed -n "s/^targetSdkVersion:'\([0-9]*\)'.*/\1/p" <<< "$BADGING" | head -1)
[[ "$MIN" =~ ^[0-9]+$ && "$TARGET" =~ ^[0-9]+$ ]] || { echo 'SDK-Metadaten fehlen' >&2; exit 1; }
SDKMANAGER=$(find "$SDK/cmdline-tools" -path '*/bin/sdkmanager' -type f | head -1)
[ -x "$SDKMANAGER" ] || { echo 'sdkmanager fehlt' >&2; exit 1; }
AVAILABLE=$("$SDKMANAGER" --list 2>/dev/null | sed -n 's/.*system-images;android-\([0-9][0-9]*\);google_apis;x86_64.*/\1/p' | sort -nu)
[ -n "$AVAILABLE" ] || { echo 'Keine google_apis/x86_64-Images verfuegbar' >&2; exit 1; }
LOW=$(awk -v min="$MIN" '$1 >= min {print; exit}' <<< "$AVAILABLE")
HIGH=$(tail -1 <<< "$AVAILABLE")
[ -n "$LOW" ] || { echo "Kein Image ab minSdk $MIN" >&2; exit 1; }
[ "$HIGH" -ge "$TARGET" ] || { echo "Oberes Image $HIGH unter targetSdk $TARGET" >&2; exit 1; }
if grep -qx 37 <<< "$AVAILABLE"; then HIGH=37; fi
printf 'minSdk=%s targetSdk=%s lower=%s upper=%s\n' "$MIN" "$TARGET" "$LOW" "$HIGH"
EV="${RUNNER_TEMP:-/tmp}/nectar-evidence"
mkdir -p "$EV/matrix"
FAILED=0
for PROFILE in lower current tablet; do
  case "$PROFILE" in lower) API="$LOW" ;; *) API="$HIGH" ;; esac
  TARGET_API="$API" ./scripts/boot-emulator.sh
  export PATH="$SDK/platform-tools:$SDK/emulator:$PATH"
  if [ "$PROFILE" = tablet ]; then
    adb shell wm size 2560x1600
    adb shell wm density 240
  fi
  ./scripts/run-smoke.sh || FAILED=1
  CRASHES=$(grep '^CRASH_COUNT=' "$GITHUB_ENV" | tail -1 | cut -d= -f2)
  [ "${CRASHES:-0}" -eq 0 ] || FAILED=1
  [ "$(tail -1 <(grep '^SHOT_OK=' "$GITHUB_ENV") | cut -d= -f2)" = 1 ] || FAILED=1
  [ "$(tail -1 <(grep '^SCREEN_STATE=' "$GITHUB_ENV") | cut -d= -f2)" = content ] || FAILED=1
  cp "$EV/screenshots/smoke-foreground.png" "$EV/screenshots/$PROFILE-api$API.png" || FAILED=1
  cp "$EV/logcat/full-logcat.txt" "$EV/logcat/$PROFILE-api$API.txt" || FAILED=1
  python3 ./scripts/verify-screenshot.py "$EV/screenshots/$PROFILE-api$API.png" || FAILED=1
  ./scripts/check-foreground.sh || FAILED=1
  adb emu kill || true
  sleep 5
done
rm -f "$EV/logcat/full-logcat.txt" "$EV/screenshots/smoke-foreground.png"
printf 'MATRIX_JSON=[{"api":"%s","label":"lower"},{"api":"%s","label":"current"},{"api":"%s","label":"tablet"}]\n' "$LOW" "$HIGH" "$HIGH" >> "$GITHUB_ENV"
echo "MATRIX_OK=$((1-FAILED))" >> "$GITHUB_ENV"
