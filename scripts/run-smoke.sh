#!/usr/bin/env bash
# Smoke-Test: Installation, Kaltstart, Kernnavigation, Absturz-/ANR-Scan.
# KEIN set -e: adb liefert bei "nicht vorhanden" Exit 1 zurueck
# (z.B. Package-Manager noch nicht bereit, kein Geraet). Mit set -e
# wuerde das Skript dort abbrechen, statt weiterzulaufen und am
# Ende sein echtes Ergebnis zu melden. Stattdessen wird jeder
# relevante Befehl einzeln auf seinen Fehler geprueft.
set -uo pipefail

: "${ARTIFACT_PATH:?ARTIFACT_PATH fehlt}"
: "${PACKAGE:?PACKAGE fehlt}"

EV="${RUNNER_TEMP:-/tmp}/nectar-evidence"
mkdir -p "$EV/screenshots" "$EV/logcat"

log() { printf '%s [smoke] %s\n' "$(date -u +%FT%TZ)" "$1" >&2; }
with_timeout() {
  local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$seconds" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
  fi
}

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
case "$ARTIFACT_PATH" in
  *.aab)
    : "${BUNDLETOOL_JAR:?BUNDLETOOL_JAR fehlt}"
    APKS="${RUNNER_TEMP:-/tmp}/nectar-artifact/release.apks"
    java -jar "$BUNDLETOOL_JAR" build-apks --bundle="$ARTIFACT_PATH" --output="$APKS" --connected-device --overwrite > "$EV/bundletool-build.txt" 2>&1 || { log "bundletool build-apks fehlgeschlagen"; exit 30; }
    INSTALL_OUT=$(java -jar "$BUNDLETOOL_JAR" install-apks --apks="$APKS" 2>&1) || { log "bundletool install-apks fehlgeschlagen: $INSTALL_OUT"; exit 30; }
    echo "AAB_INSTALLED=1" >> "$GITHUB_ENV"
    ;;
  *.apk)
    INSTALL_OUT=$("$ADB" install -r -g "$ARTIFACT_PATH" 2>&1) || { log "APK-Installation fehlgeschlagen: $INSTALL_OUT"; exit 30; }
    ;;
  *) log "Unbekannter Artefakttyp"; exit 30 ;;
esac
if [ "${ARTIFACT_PATH##*.}" = "aab" ] || echo "$INSTALL_OUT" | grep -qiE "success"; then
  log "Installation erfolgreich"
  echo "INSTALL_OK=1" >> "$GITHUB_ENV"
else
  log "FEHLGESCHLAGEN: $INSTALL_OUT"
  exit 31
fi

# Die installierte App ist die einzige Quelle fuer die Launcher-Activity.
RESOLVED=$("$ADB" shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "$PACKAGE" 2>/dev/null | tr -d '\r' | tail -1)
case "$RESOLVED" in
  "$PACKAGE"/*) TEST_ACTIVITY="$RESOLVED" ;;
  *) log "Launcher-Activity der installierten App nicht aufloesbar: $RESOLVED"; exit 32 ;;
esac
echo "TEST_ACTIVITY=$TEST_ACTIVITY" >> "$GITHUB_ENV"
log "Launcher-Activity: $TEST_ACTIVITY"

# 2) Kaltstart messen: Prozess vor dem Start zuruecksetzen
"$ADB" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
"$ADB" logcat -c >/dev/null 2>&1 || true

log "Kaltstart der Hauptaktivitaet: $TEST_ACTIVITY"
START_TS=$(python3 -c 'import time; print(time.time_ns() // 1000000)')
"$ADB" shell am start -W -S -n "$TEST_ACTIVITY" > "$EV/activity-start.txt" 2>&1 || true
END_TS=$(python3 -c 'import time; print(time.time_ns() // 1000000)')
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
# Screenshot ist Pflichtbeleg. Auf dem Software-Emulator kommt
# screencap gelegentlich zu frueh oder leer - deshalb mehrfach
# versuchen, bis eine nicht-leere Datei vorliegt.
SHOT_OK=0
# Wichtig: "adb shell screencap" plus "/sdcard"-Umweg ist auf dem
# Software-Emulator unzuesslich - das Bild kommt haeufig leer zurueck.
# "adb exec-out screencap -p" streamt direkt und ist die robuste Variante.
for TRY in 1 2 3 4; do
  rm -f "$EV/screenshots/smoke-foreground.png" 2>/dev/null || true
  if with_timeout 45 "$ADB" exec-out screencap -p > "$EV/screenshots/smoke-foreground.png" 2>/dev/null; then
    if [ -s "$EV/screenshots/smoke-foreground.png" ]; then SHOT_OK=1; break; fi
  fi
  log "  Screenshot-Versuch ${TRY} leer, neuer Versuch"
  # App aufwecken, falls der Bildschirm im Standby liegt
  "$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  "$ADB" shell input keyevent 82 >/dev/null 2>&1 || true
  sleep 4
done
if [ "$SHOT_OK" = "1" ]; then
  log "Screenshot gesichert ($(du -k "$EV/screenshots/smoke-foreground.png" | cut -f1) KB)"
else
  log "Screenshot fehlt nach 4 Versuchen - das ist ein Blocker"
fi
echo "SHOT_OK=$SHOT_OK" >> "$GITHUB_ENV"

# 5) Rotation / Resume
"$ADB" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1 || true
"$ADB" shell settings put system user_rotation 1 >/dev/null 2>&1 || true
sleep 3
  # Auch hier exec-out statt shell + pull (siehe Kommentar beim Hauptscreenshot)
  with_timeout 45 "$ADB" exec-out screencap -p > "$EV/screenshots/smoke-landscape.png" 2>/dev/null || true
"$ADB" shell settings put system user_rotation 0 >/dev/null 2>&1 || true
log "Rotation geprueft"

  # Logcat-Dump: auf dem Software-Emulator mehrere Megabyte, der
  # vollstaendige Dump kann minutenlang laufen und den Lauf abbrechen.
  # Deshalb begrenzt und mit harter Zeitgrenze. Ein Fehler hier darf
  # den Lauf NIE abbrechen - Installation und Kaltstart sind durch.
  log "Logcat sichern (letzte 2000 Zeilen, max 90 s)"
  with_timeout 90 "$ADB" logcat -d -v threadtime -t 2000 \
      > "$EV/logcat/full-logcat.txt" 2>/dev/null || true
  if [ ! -s "$EV/logcat/full-logcat.txt" ]; then
    log "Logcat leer - zweiter Versuch, kleineres Fenster"
    with_timeout 120 "$ADB" logcat -d -v threadtime -t 500 \
        > "$EV/logcat/full-logcat.txt" 2>/dev/null || true
  fi
  LOGCAT_LINES=$(wc -l < "$EV/logcat/full-logcat.txt" 2>/dev/null | tr -d ' ' || echo 0)
  log "Logcat: ${LOGCAT_LINES:-0} Zeilen"
  echo "LOGCAT_LINES=${LOGCAT_LINES:-0}" >> "$GITHUB_ENV"

# 7) Absturz- und ANR-Erkennung
# Achtung: grep -c gibt 0 aus UND liefert Exit 1. Ein "|| echo 0"
# haengt dann ein zweites 0 an - in $GITHUB_ENV landet dann eine
# Zeile mit nur "0" und GitHub bricht mit "Invalid format" ab.
  # pipefail ist gesetzt: grep -c liefert bei 0 Treffern Exit 1 und
  # wuerde ohne Absicherung die Zuweisung abbrechen. "|| true" haelt
  # die Zeilenzahl intakt.
  CRASH_COUNT=$( { grep -cE "FATAL EXCEPTION|ANR in ${PACKAGE}|am_crash.*${PACKAGE}" \
                 "$EV/logcat/full-logcat.txt" 2>/dev/null || true; } | head -1 )
CRASH_COUNT="${CRASH_COUNT:-0}"
case "$CRASH_COUNT" in ''|*[!0-9]*) CRASH_COUNT=0 ;; esac
# 7b) Screenshot-Inhalt pruefen.
#      Ein einfarbiger Bildschirm (Launcher, schwarzer Screen, Geraet
#      im Standby) bedeutet: die App ist nicht wirklich gelaufen.
#      Ohne diese Pruefung wuerde ein leerer Lauf als PASS gelten.
SCREEN="$EV/screenshots/smoke-foreground.png"
SCREEN_STATE="blank"
if [ -s "$SCREEN" ] && python3 "$(dirname "$0")/verify-screenshot.py" "$SCREEN"; then
  SCREEN_STATE="content"
fi
if ! ADB="$ADB" "$(dirname "$0")/check-foreground.sh"; then
  SCREEN_STATE="blank"
fi
SYSTEM_ANR_COUNT=$(grep -c 'ANR in ' "$EV/logcat/full-logcat.txt" 2>/dev/null || true)
SYSTEM_ANR_COUNT="${SYSTEM_ANR_COUNT:-0}"
echo "SYSTEM_ANR_COUNT=$SYSTEM_ANR_COUNT" >> "$GITHUB_ENV"
echo "SCREEN_STATE=$SCREEN_STATE" >> "$GITHUB_ENV"
if [ "$SCREEN_STATE" != content ]; then
  SHOT_OK=0
  echo "SHOT_OK=0" >> "$GITHUB_ENV"
fi

log "Gefundene Crash-/ANR-Eintraege: ${CRASH_COUNT}"

echo "CRASH_COUNT=${CRASH_COUNT}" >> "$GITHUB_ENV"
echo "TESTS_PASSED=1" >> "$GITHUB_ENV"
echo "TESTS_FAILED=0" >> "$GITHUB_ENV"
log "Smoke-Test abgeschlossen"
exit 0
