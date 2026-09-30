#!/usr/bin/env bash
set -euo pipefail
: "${ARTIFACT_PATH:?}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
SDKMANAGER=$(find "$SDK/cmdline-tools" -path '*/bin/sdkmanager' -type f | head -1)
[ -x "$SDKMANAGER" ] || { echo 'sdkmanager fehlt' >&2; exit 1; }
AVAILABLE=$("$SDKMANAGER" --list 2>/dev/null | sed -n 's/.*system-images;android-\([0-9][0-9]*\);google_apis;x86_64.*/\1/p' | sort -nu)
[ -n "$AVAILABLE" ] || { echo 'Keine System-Images verfuegbar' >&2; exit 1; }
if [[ "$ARTIFACT_PATH" == *.apk ]]; then
  AAPT=$(find "$SDK/build-tools" -maxdepth 2 -name aapt -type f | sort -V | tail -1)
  BADGING=$("$AAPT" dump badging "$ARTIFACT_PATH")
  MIN=$(sed -n "s/^sdkVersion:'\([0-9]*\)'.*/\1/p" <<< "$BADGING" | head -1)
  TARGET=$(sed -n "s/^targetSdkVersion:'\([0-9]*\)'.*/\1/p" <<< "$BADGING" | head -1)
else
  : "${BUNDLETOOL_JAR:?}"
  MIN=$(java -jar "$BUNDLETOOL_JAR" dump manifest --bundle="$ARTIFACT_PATH" --xpath='/manifest/uses-sdk/@android:minSdkVersion' | tr -dc '0-9')
  TARGET=$(java -jar "$BUNDLETOOL_JAR" dump manifest --bundle="$ARTIFACT_PATH" --xpath='/manifest/uses-sdk/@android:targetSdkVersion' | tr -dc '0-9')
fi
[[ "$MIN" =~ ^[0-9]+$ && "$TARGET" =~ ^[0-9]+$ ]] || { echo 'SDK-Metadaten fehlen' >&2; exit 1; }
if [ -n "${REQUESTED_API:-}" ]; then
  API="$REQUESTED_API"
  grep -qx "$API" <<< "$AVAILABLE" || { echo "API $API nicht verfuegbar" >&2; exit 1; }
else
  API=$(tail -1 <<< "$AVAILABLE")
  grep -qx 37 <<< "$AVAILABLE" && API=37
fi
[ "$API" -ge "$MIN" ] || { echo "API $API unter minSdk $MIN" >&2; exit 1; }
printf 'Artefakt minSdk=%s targetSdk=%s; Emulator API=%s\n' "$MIN" "$TARGET" "$API"
echo "TARGET_API=$API" >> "${GITHUB_ENV:?}"
