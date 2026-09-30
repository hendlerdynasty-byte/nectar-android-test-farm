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
set -uo pipefail

TARGET_API="${TARGET_API:-34}"
TARGET_TAG="${TARGET_TAG:-google_apis}"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"

log() { printf '%s [boot-emulator] %s\n' "$(date -u +%FT%TZ)" "$1" >&2; }
die()  { log "FEHLGESCHLAGEN: $1"; exit "${2:-20}"; }

# ── Werkzeuge ueber absolute Pfade auffinden ───────────────────
# Der Runner setzt ANDROID_HOME, aber NICHT den cmdline-tools-Pfad.
# Ohne diese Aufloesung endet jedes Skript mit exit 127.
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
[ -d "$SDK" ] || die "ANDROID_HOME nicht gefunden (${SDK})" 25

find_tool() {
  local name="$1" cand
  case "$name" in
    emulator) [ -x "$SDK/emulator/emulator" ] && { echo "$SDK/emulator/emulator"; return 0; } ;;
    adb) [ -x "$SDK/platform-tools/adb" ] && { echo "$SDK/platform-tools/adb"; return 0; } ;;
  esac
  cand="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$cand" ] && [ -x "$cand" ]; then echo "$cand"; return 0; fi
  # Bekannte Orte in den cmdline-tools-Versionen
  for p in "$SDK"/cmdline-tools/*/bin/"$name" \
           "$SDK"/tools/bin/"$name" \
           "$SDK"/platform-tools/"$name" \
           "$SDK"/emulator/"$name"; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

SDKMANAGER="$(find_tool sdkmanager || true)"

# Das GitHub-Runner-Image enthaelt KEINEN Android-Emulator.
# Er wird deshalb bei Bedarf nachinstalliert (kostenlos in oeffentlichen Repos).
if [ -n "$SDKMANAGER" ]; then
  if [ ! -x "${SDK}/emulator/emulator" ] && [ ! -x "${SDK}/platform-tools/adb" ]; then
    printf '%s [boot-emulator] %s\n' "$(date -u +%FT%TZ)" \
      "Emulator/Platform-Tools fehlen im Image - Installation startet (2-5 min)" >&2
    "$SDKMANAGER" "emulator" "platform-tools" >/dev/null 2>&1 || true
  fi
  if [ ! -x "${SDK}/platform-tools/adb" ]; then
    "$SDKMANAGER" "platform-tools" >/dev/null 2>&1 || true
  fi
  if [ ! -x "${SDK}/emulator/emulator" ]; then
    "$SDKMANAGER" "emulator" >/dev/null 2>&1 || true
  fi
fi
AVDMANAGER="$(find_tool avdmanager || true)"
EMULATOR="$(find_tool emulator || true)"
ADB="$(find_tool adb || true)"

# AVD-Speicherort explizit festlegen.
# Ohne das legt avdmanager die AVD an einem Ort ab, an dem der
# Emulator sie nicht findet ("Unknown AVD name").
AVD_HOME="${HOME}/.android/avd"
mkdir -p "$AVD_HOME"
export ANDROID_AVD_HOME="$AVD_HOME"
log "AVD_HOME: ${AVD_HOME}"

log "SDK: ${SDK}"
log "sdkmanager:  ${SDKMANAGER:-FEHLT}"
log "avdmanager:  ${AVDMANAGER:-FEHLT}"
log "emulator:    ${EMULATOR:-FEHLT}"
log "adb:         ${ADB:-FEHLT}"

[ -n "$SDKMANAGER" ] || die "sdkmanager nicht gefunden" 26
[ -n "$AVDMANAGER" ] || die "avdmanager nicht gefunden" 27
[ -n "$EMULATOR" ]   || { log "Hinweis: Der Emulator konnte nicht installiert werden."
                          log "Manuelle Pruefung: ls ${SDK}/emulator/"; }
[ -n "$ADB" ]        || die "adb nicht gefunden" 29

# ── KVM pruefen ────────────────────────────────────────────────
if [ "$(uname -s)" = Darwin ] && "$EMULATOR" -accel-check 2>&1 | grep -qi 'usable'; then
  log "macOS Hypervisor-Beschleunigung verfuegbar"
  ACCEL_FLAG="-accel on"
  ACCEL_MODE="hardware"
elif [ -e /dev/kvm ] && [ -r /dev/kvm ]; then
  log "/dev/kvm vorhanden - Hardware-Beschleunigung moeglich"
  ACCEL_FLAG=""
  ACCEL_MODE="hardware"
else
  log "kein /dev/kvm - Software-Emulation (langsamer Boot, 0 EUR)"
  ACCEL_FLAG="-accel off"
  ACCEL_MODE="software"
fi

# ── Lizenzen annehmen ──────────────────────────────────────────
# "yes | sdkmanager --licenses" erzeugt absichtlich einen Broken Pipe.
# Deshalb: kein set -e, Ausgabe unterdruecken, Fehler tolerieren.
{
  yes 2>/dev/null || true
} | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
log "Lizenzen akzeptiert (best effort)"

# ── System-Image ───────────────────────────────────────────────
SYSTEM_IMAGE="system-images;android-${TARGET_API};${TARGET_TAG};${TARGET_ARCH}"
log "System-Image sicherstellen: ${SYSTEM_IMAGE}"
"$SDKMANAGER" "${SYSTEM_IMAGE}" >/dev/null 2>&1 || true

# Bereits im Image vorhanden?
if [ -d "${SDK}/system-images/android-${TARGET_API}/${TARGET_TAG}/${TARGET_ARCH}" ]; then
  log "System-Image war bereits vorhanden"
else
  log "HINWEIS: System-Image-Verzeichnis fehlt weiterhin - Boot wird vermutlich scheitern"
fi

# ── AVD anlegen ────────────────────────────────────────────────
AVD_NAME="nectar-api${TARGET_API}"
log "AVD anlegen: ${AVD_NAME}"
{
  echo "no"
} | "$AVDMANAGER" create avd -n "${AVD_NAME}" -k "${SYSTEM_IMAGE}" --force >/dev/null 2>&1 || true
if [ ! -f "${AVD_HOME}/${AVD_NAME}.ini" ]; then
  log "AVD-.ini fehlt unter ${AVD_HOME} - breite Suche:"
  find "$HOME/.android" "$SDK" -maxdepth 4 -name "${AVD_NAME}.ini" 2>/dev/null | head -3 | sed 's/^/    /'
  die "AVD nicht dort angelegt, wo der Emulator sucht" 23
fi
log "AVD-Datei bestaetigt: ${AVD_HOME}/${AVD_NAME}.ini"

# ── Emulator starten ────────────────────────────────────────────
log "Emulator starten (${ACCEL_MODE})"
nohup "$EMULATOR" \
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
log "Emulator-Prozess ${EMU_PID}, warte auf sys.boot_completed"

# adb auf den Server warten
"$ADB" start-server >/dev/null 2>&1 || true
for i in $(seq 1 30); do
  "$ADB" devices 2>/dev/null | grep -q "device$" && break
  sleep 5
done

BOOT_TIMEOUT=1500
WAITED=0
BOOTED=0
until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ')" = "1" ]; do
  sleep 15
  WAITED=$((WAITED + 15))
  if ! kill -0 "${EMU_PID}" 2>/dev/null; then
    log "Emulatorprozess beendet - Log:"
    tail -30 /tmp/emulator.log >&2 || true
    die "Emulatorprozess beendet" 21
  fi
  if [ "${WAITED}" -ge "${BOOT_TIMEOUT}" ]; then
    log "Log des Emulators:"
    tail -30 /tmp/emulator.log >&2 || true
    die "Emulator nach ${BOOT_TIMEOUT}s nicht gebootet" 20
  fi
  [ $((WAITED % 120)) -eq 0 ] && log "  ... wartet noch (${WAITED}s)"
done
BOOTED=1
log "Gebootet nach ${WAITED}s"

# ── Auf den Package-Manager warten ──────────────────────────────
# sys.boot_completed=1 wird gesetzt, BEVOR der Package-Manager
# bereit ist. Ohne diese Warte scheitert jede Installation mit
# "Can't find service: package". In Software-Emulation ist die
# Verzoegerung deutlich groesser als mit KVM.
log "Warte auf Package-Manager"
PM_WAITED=0
PM_TIMEOUT=300
until [ "$("$ADB" shell service check package 2>/dev/null | tr -d '\r\n ')" = "found" ]; do
  sleep 10
  PM_WAITED=$((PM_WAITED + 10))
  if [ "${PM_WAITED}" -ge "${PM_TIMEOUT}" ]; then
    log "WARNUNG: Package-Manager nach ${PM_TIMEOUT}s nicht bereit"
    break
  fi
  [ $((PM_WAITED % 60)) -eq 0 ] && log "  ... warte noch (${PM_WAITED}s)"
done
log "Package-Manager bereit nach ${PM_WAITED}s"

# ── Geraet vorbereiten ─────────────────────────────────────────
"$ADB" shell input keyevent 82 >/dev/null 2>&1 || true
"$ADB" shell settings put global window_animation_scale 0 >/dev/null 2>&1 || true
"$ADB" shell settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
"$ADB" shell settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
"$ADB" shell svc wifi disable >/dev/null 2>&1 || true
"$ADB" shell svc power stayon true >/dev/null 2>&1 || true

DEVICE_SERIAL="$("$ADB" devices | awk 'NR==2{print $1}')"
[ -n "$DEVICE_SERIAL" ] || die "kein Geraet sichtbar" 22
API_LEVEL="$("$ADB" shell getprop ro.build.version.sdk | tr -d '\r\n ')"
MODEL="$("$ADB" shell getprop ro.product.model | tr -d '\r\n ')"
RELEASE="$("$ADB" shell getprop ro.build.version.release | tr -d '\r\n ')"

{
  echo "DEVICE_SERIAL=${DEVICE_SERIAL}"
  echo "DEVICE_API=${API_LEVEL}"
  echo "DEVICE_MODEL=${MODEL}"
  echo "DEVICE_RELEASE=${RELEASE}"
  echo "DEVICE_AVD=${AVD_NAME}"
  echo "ACCELERATION=${ACCEL_MODE}"
  echo "BOOT_SECONDS=${WAITED}"
} >> "${GITHUB_ENV}"

# Werkzeugpfade fuer die Folgeschritte exportieren.
# GitHub-Runner setzt ANDROID_HOME, aber platform-tools und emulator
# liegen NICHT im PATH. Ohne dieses export scheitert jedes
# nachfolgende Skript mit "command not found".
for d in "$SDK/platform-tools" "$SDK/emulator" "$SDK/cmdline-tools/latest/bin"; do
  [ -d "$d" ] && printf '%s\n' "$d" >> "${GITHUB_PATH:?GITHUB_PATH fehlt}"
done
log "PATH ergaenzt: $(command -v adb) / $(command -v emulator)"

log "Bereit: ${MODEL}, API ${API_LEVEL} (Android ${RELEASE})"
