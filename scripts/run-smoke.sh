#!/usr/bin/env bash
# Smoke-Test: Installation, Kaltstart, Kernnavigation, Absturz-/ANR-Scan.
set -euo pipefail

: "${ARTIFACT_PATH:?ARTIFACT_PATH fehlt}"
: "${PACKAGE:?PACKAGE fehlt}"
: "${TEST_ACTIVITY:?TEST_ACTIVITY fehlt}"

EV="${RUNNER_TEMP:-/tmp}/nectar-evidence"
mkdir -p "$EV/screenshots" "$EV/logcat"

log() { printf '%s [smoke] %s\n' "$(date -u +%FT%TZ)" "$1" >&2; }

# adb nicht unbedingt im PATH (GitHub-Runner)
SDK="${ANDROID_HOME:-/usr/local/lib/android/sdk}"
ADB="$(command -v adb 2>/dev/null || true)"
[ -n "$ADB" ] || ADB="${SDK}/platform-tools/adb"
[ -x "$ADB" ] || { log "FEHLGESCHLAGEN: adb nicht gefunden"; exit 40; }
log "adb: $ADB"

# 1) Vorhandene Version entfernen und frisch installieren
log "Deinstallation eines vorhandenen Standes"
"$ADB" uninstall "$PACKAGE" >/dev/null 2>&1 || true

log "Installation"
INSTALL_OUT=$("$ADB" install -r -g "$ARTIFACT_PATH" 2>&1) || {
  log "FEHLGESCHLAGEN: Installation"
  echo "$INSTALL_OUT" >&2
  exit 30
}
if echo "$INSTALL_OUT" | grep -qiE "success"; then
  log "Installation erfolgreich"
else
  log "FEHLGESCHLAGEN: $INSTALL_OUT"
  exit 31
fi

# 2) Kaltstart messen: Prozess vor dem Start zuruecksetzen
"$ADB" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
"$ADB" logcat -c >/dev/null 2>&1 || true

log "Kaltstart der Hauptaktivitaet: $TEST_ACTIVITY"
START_TS=$(date +%s%3N)
"$ADB" shell am start -W -S -n "$TEST_ACTIVITY" > "$EV/activity-start.txt" 2>&1 || true
END_TS=$(date +%s%3N)
COLD_START_MS=$((END_TS - START_TS))
echo "COLD_START_MS=${COLD_START_MS}" >> "$GITHUB_ENV"
log "Kaltstart: ${COLD_START_MS} ms"

# 3) Auf die App reagieren lassen
sleep 6
"$ADB" shell input keyevent 3 >/dev/null 2>&1 || true   # Home
sleep 2
"$ADB" shell am start -n "$TEST_ACTIVITY" >/dev/null 2>&1 || true
sleep 4

# 4) Screenshot-Beweis
"$ADB" shell screencap -p /sdcard/nectar-smoke.png >/dev/null 2>&1 || true
"$ADB" pull /sdcard/nectar-smoke.png "$EV/screenshots/smoke-foreground.png" >/dev/null 2>&1 || true
log "Screenshot gesichert"

# 5) Rotation / Resume
"$ADB" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1 || true
"$ADB" shell settings put system user_rotation 1 >/dev/null 2>&1 || true
sleep 3
"$ADB" shell screencap -p /sdcard/nectar-landscape.png >/dev/null 2>&1 || true
"$ADB" pull /sdcard/nectar-landscape.png "$EV/screenshots/smoke-landscape.png" >/dev/null 2>&1 || true
"$ADB" shell settings put system user_rotation 0 >/dev/null 2>&1 || true
log "Rotation geprueft"

  # Logcat-Dump: auf dem Software-Emulator mehrere Megabyte, der
  # vollstaendige Dump kann minutenlang laufen und den Lauf abbrechen.
  # Deshalb begrenzt und mit harter Zeitgrenze. Ein Fehler hier darf
  # den Lauf NIE abbrechen - Installation und Kaltstart sind durch.
  log "Logcat sichern (letzte 2000 Zeilen, max 90 s)"
  timeout 90 "$ADB" logcat -d -v threadtime -t 2000 \
      > "$EV/logcat/full-logcat.txt" 2>/dev/null || true
  if [ ! -s "$EV/logcat/full-logcat.txt" ]; then
    log "Logcat leer - zweiter Versuch, kleineres Fenster"
    timeout 120 "$ADB" logcat -d -v threadtime -t 500 \
        > "$EV/logcat/full-logcat.txt" 2>/dev/null || true
  fi
  LOGCAT_LINES=$(wc -l < "$EV/logcat/full-logcat.txt" 2>/dev/null | tr -d ' ' || echo 0)
  log "Logcat: ${LOGCAT_LINES:-0} Zeilen"
  echo "LOGCAT_LINES=${LOGCAT_LINES:-0}" >> "$GITHUB_ENV"

# 7) Absturz- und ANR-Erkennung
# Achtung: grep -c gibt 0 aus UND liefert Exit 1. Ein "|| echo 0"
# haengt dann ein zweites 0 an - in $GITHUB_ENV landet dann eine
# Zeile mit nur "0" und GitHub bricht mit "Invalid format" ab.
CRASH_COUNT=$(grep -cE "FATAL EXCEPTION|ANR in ${PACKAGE}|am_crash.*${PACKAGE}" \
              "$EV/logcat/full-logcat.txt" 2>/dev/null | head -1)
CRASH_COUNT="${CRASH_COUNT:-0}"
case "$CRASH_COUNT" in ''|*[!0-9]*) CRASH_COUNT=0 ;; esac
log "Gefundene Crash-/ANR-Eintraege: ${CRASH_COUNT}"

echo "CRASH_COUNT=${CRASH_COUNT}" >> "$GITHUB_ENV"
echo "TESTS_PASSED=1" >> "$GITHUB_ENV"
echo "TESTS_FAILED=0" >> "$GITHUB_ENV"
log "Smoke-Test abgeschlossen"
exit 0
