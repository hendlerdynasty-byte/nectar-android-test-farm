#!/usr/bin/env bash
# Lädt ein Test-Artefakt von der privaten Bridge (Contabo).
#
# Datenschutz-Eigenschaften (diese Skript ist das sicherheitskritische Stück):
#   * Der öffentliche Test-Farm klont NIEMALS das private App-Repository.
#   * Der Workflow kennt nur eine opake build_id, niemals Quellcode.
#   * Das Artefakt wird über HTTPS mit einem Repository-Secret geholt.
#   * Der Secret-Wert wird nie ausgegeben, nie in die Logs geschrieben.
#   * Das Artefakt verschwindet nach dem Download vom Runner.
#
# Umgebungsvariablen (Pflicht):
#   BRIDGE_URL        Basis-URL der Bridge, z.B. https://host:port
#   BRIDGE_TOKEN      Repository-Secret für die Authentifizierung
#   BUILD_ID          opake UUID des Laufs
#   ARTIFACT_NAME     Dateiname des Artefakts, z.B. app-debug.apk
#
# Umgebungsvariablen (optional):
#   ARTIFACT_SHA256   erwarteter Prüfsumme; wenn gesetzt, wird fail-closed geprüft
set -euo pipefail

: "${BRIDGE_URL:?BRIDGE_URL fehlt}"
: "${BRIDGE_TOKEN:?BRIDGE_TOKEN fehlt}"
: "${BUILD_ID:?BUILD_ID fehlt}"
: "${ARTIFACT_NAME:?ARTIFACT_NAME fehlt}"

WORKDIR="${RUNNER_TEMP:-/tmp}/nectar-artifact"
mkdir -p "$WORKDIR"
DEST="$WORKDIR/$ARTIFACT_NAME"

log() { printf '%s [fetch-artifact] %s\n' "$(date -u +%FT%TZ)" "$1" >&2; }

# build_id muss streng UUID-Form sein - schützt vor Pfad-Traversal.
if ! printf '%s' "$BUILD_ID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  log "ABGELEHNT: build_id ist keine gueltige UUID"
  exit 10
fi

# artifact_name darf keine Pfadbestandteile enthalten.
case "$ARTIFACT_NAME" in
  */*|*..*|\\*)
    log "ABGELEHNT: artifact_name enthaelt unzulaessige Zeichen"
    exit 11
    ;;
esac

URL="${BRIDGE_URL%/}/v1/artifacts/${BUILD_ID}/${ARTIFACT_NAME}"
log "hole Artefakt fuer build_id=${BUILD_ID}"

HTTP_CODE=$(curl -sS -L \
  -H "Authorization: Bearer ${BRIDGE_TOKEN}" \
  -H "Accept: application/octet-stream" \
  --max-time 300 \
  -o "$DEST" \
  -w '%{http_code}' \
  "$URL" || echo "000")

if [ "$HTTP_CODE" != "200" ]; then
  log "FEHLGESCHLAGEN: Bridge antwortete mit HTTP ${HTTP_CODE}"
  exit 12
fi

if [ ! -s "$DEST" ]; then
  log "FEHLGESCHLAGEN: Artefakt ist leer"
  exit 13
fi

# sha256sum (coreutils) ist auf Linux immer vorhanden, shasum nicht.
if command -v sha256sum > /dev/null 2>&1; then
  ACTUAL_SHA=$(sha256sum "$DEST" | awk '{print $1}')
elif command -v shasum > /dev/null 2>&1; then
  ACTUAL_SHA=$(shasum -a 256 "$DEST" | awk '{print $1}')
else
  log "FEHLGESCHLAGEN: kein sha256sum und kein shasum vorhanden"
  exit 15
fi

# fail closed: Wenn eine erwartete Prüfsumme vorliegt, muss sie stimmen.
if [ -n "${ARTIFACT_SHA256:-}" ]; then
  if [ "$ACTUAL_SHA" != "$ARTIFACT_SHA256" ]; then
    log "FEHLGESCHLAGEN: Pruefsumme stimmt nicht (erwartet ${ARTIFACT_SHA256})"
    rm -f "$DEST"
    exit 14
  fi
  log "Pruefsumme bestaetigt: ${ACTUAL_SHA}"
else
  log "HINWEIS: keine erwartete Pruefsumme angegeben - Integritaet nicht vorab beweisbar"
fi

echo "ARTIFACT_PATH=$DEST" >> "$GITHUB_ENV"
echo "ARTIFACT_SHA256=$ACTUAL_SHA" >> "$GITHUB_ENV"
log "OK: Artefakt bereit (${ACTUAL_SHA})"
