#!/usr/bin/env bash
# Startet den Android-Emulator im Software-Modus und wartet auf den Boot.
#
# WICHTIG - Betriebsrealitaet:
#   GitHub-gehostete Runner bieten KEINE verschachtelte Virtualisierung,
#   /dev/kvm ist dort nicht vorhanden. Der Emulator laeuft deshalb
#   zwingend ohne Hardware-Beschleunigung (softwaregeraetete TCG).
#   Das ist langsamer beim Boot (typisch 5-15 min), aber funktionsfaehig
#   und kostet 0 EUR.
#
# Variable:
#   TARGET_API   Android-API-Level (Standard 34)
#   TARGET_TAG   System-Image-Tag (Standard google_apis)
#   TARGET_ARCH  Architektur (Standard x86_64)
set -euo pipefail

TARGET_API="${TARGET_API:-34}"
TARGET_TAG="${TARGET_TAG:-google_apis}"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"

log() { printf '%s [boot-emulator] %s\n' "$(date -u +%FT%TZ)" "$1" >&2; }

log "KVM-Verfuegbarkeit pruefen"
if [ -e /dev/kvm ] && [ -r /dev/kvm ]; then
  log "/dev/kvm vorhanden - Hardware-Beschleunigung moeglich"
  ACCEL_FLAG=""
else
  log "kein /dev/kvm - Software-Emulation (langsamer Boot, 0 EUR)"
  ACCEL_FLAG="-accel off"
fi

AVD_NAME="nectar-api${TARGET_API}"
SYSTEM_IMAGE="system-images;android-${TARGET_API};${TARGET_TAG};${TARGET_ARCH}"

log "System-Image sicherstellen: ${SYSTEM_IMAGE}"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager "${SYSTEM_IMAGE}" >/dev/null 2>&1

log "AVD anlegen: ${AVD_NAME}"
echo "no" | avdmanager create avd \
  -n "${AVD_NAME}" \
  -k "${SYSTEM_IMAGE}" \
  --force >/dev/null 2>&1

log "Emulator starten"
nohup emulator \
  -avd "${AVD_NAME}" \
  -no-window \
  -no-audio \
  -no-boot-anim \
  -no-snapshot \
  -gpu swiftshader_indirect \
  -camera-back none \
  -camera-front none \
  ${ACCEL_FLAG} \
  > /tmp/emulator.log 2>&1 &

EMU_PID=$!
log "Emulator-Prozess ${EMU_PID}, warte auf sys.boot_completed (max 20 min)"

BOOT_TIMEOUT=1200
WAITED=0
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ')" = "1" ]; do
  sleep 10
  WAITED=$((WAITED + 10))
  if [ "${WAITED}" -ge "${BOOT_TIMEOUT}" ]; then
    log "FEHLGESCHLAGEN: Emulator nach ${BOOT_TIMEOUT}s nicht gebootet"
    tail -40 /tmp/emulator.log >&2 || true
    exit 20
  fi
  # Prozess-Drama frueh erkennen
  if ! kill -0 "${EMU_PID}" 2>/dev/null; then
    log "FEHLGESCHLAGEN: Emulatorprozess beendet"
    tail -40 /tmp/emulator.log >&2 || true
    exit 21
  fi
  if [ $((WAITED % 120)) -eq 0 ]; then
    log "  ... wartet noch (${WAITED}s)"
  fi
done

log "Gebootet nach ${WAITED}s"

# Wichtige Vorkehrungen: Bildschirm an, Wecker aus, entsperrt
adb shell input keyevent 82 >/dev/null 2>&1 || true
adb shell settings put global window_animation_scale 0 >/dev/null 2>&1 || true
adb shell settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
adb shell settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
adb shell svc wifi disable >/dev/null 2>&1 || true
adb shell svc power stayon true >/dev/null 2>&1 || true

DEVICE_SERIAL=$(adb devices | awk 'NR==2{print $1}')
[ -n "$DEVICE_SERIAL" ] || { log "FEHLGESCHLAGEN: kein Geraet sichtbar"; exit 22; }
API_LEVEL=$(adb shell getprop ro.build.version.sdk | tr -d '\r\n ')
MODEL=$(adb shell getprop ro.product.model | tr -d '\r\n ')
RELEASE=$(adb shell getprop ro.build.version.release | tr -d '\r\n ')

{
  echo "DEVICE_SERIAL=$DEVICE_SERIAL"
  echo "DEVICE_API=$API_LEVEL"
  echo "DEVICE_MODEL=$MODEL"
  echo "DEVICE_RELEASE=$RELEASE"
  echo "DEVICE_AVD=$AVD_NAME"
  echo "ACCELERATION=$([ -n "$ACCEL_FLAG" ] && echo software || echo hardware)"
} >> "$GITHUB_ENV"

log "Bereit: ${MODEL}, API ${API_LEVEL} (Android ${RELEASE}), serielle ${DEVICE_SERIAL}"
