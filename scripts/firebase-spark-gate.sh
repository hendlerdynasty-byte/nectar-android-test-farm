#!/usr/bin/env bash
# Firebase Test Lab Spark - Gate fuer Release-Kandidaten.
#
# WICHTIG - Kostenregel:
#   Dieses Skript aktiviert NIEMALS eine Zahlungsmethode. Ohne
#   hinterlegte Zahlungsart laeuft Test Lab im kostenlosen
#   Spark-Kontingent. Ist es erschoepft, endet der Lauf mit
#   ZERO_COST_BLOCKED - es wird kein Bezahlpfad eingeschlagen.
#
#   Firebase Test Lab Spark bietet ein taegliches kostenloses
#   Kontingent. Voraussetzung ist ein aktives Spark-Kontingent
#   im Projekt; das wird NICHT automatisch beantragt.
#
# Aufruf:
#   firebase-spark-gate.sh --check          # nur Verfuegbarkeit pruefen
#   firebase-spark-gate.sh --run <app> <aab> <package>
set -uo pipefail

PROJEKT="${FIREBASE_PROJECT_ID:-}"
MODE="check"
APP=""; AAB=""; PACKAGE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --run)   MODE="run"; APP="${2:-}"; AAB="${3:-}"; PACKAGE="${4:-}"; shift 4 ;;
    *) shift ;;
  esac
done

log() { printf '%s [firebase-spark] %s\n' "$(date +%H:%M:%S)" "$1"; }
gate() { log "VERDIKT: $1"; echo "VERDICT=$1"; }

# ── Ist das Werkzeug ueberhaupt da? ────────────────────────────
if ! command -v gcloud > /dev/null 2>&1; then
  log "gcloud nicht installiert - Gate wird uebersprungen, NICHT als Fehler gewertet"
  gate "SKIPPED_NO_TOOL"
  exit 0
fi
if [ -z "$PROJEKT" ]; then
  log "FIREBASE_PROJECT_ID nicht gesetzt - Gate uebersprungen"
  gate "SKIPPED_NO_PROJECT"
  exit 0
fi

# ── Ist der Nutzer angemeldet? ─────────────────────────────────
if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
  log "Keine aktive gcloud-Anmeldung - Gate uebersprungen"
  gate "SKIPPED_NO_AUTH"
  exit 0
fi

# ── Ist das Projekt erreichbar? ────────────────────────────────
if ! gcloud projects describe "$PROJEKT" > /dev/null 2>&1; then
  log "Projekt ${PROJEKT} nicht erreichbar - Gate uebersprungen"
  gate "SKIPPED_NO_PROJECT_ACCESS"
  exit 0
fi

# ── Spark-Kontingent pruefen (nur lesend) ─────────────────────
# Wichtig: Es wird NIE "billing enable" aufgerufen.
SPARK=$(gcloud beta firebase test android models list \
          --project="$PROJEKT" --format='value(name)' 2>/dev/null | head -1)
if [ -n "$SPARK" ]; then
  log "Spark-Modell verfuegbar: ${SPARK}"
else
  log "Kein Spark-Modell sichtbar"
  gate "ZERO_COST_BLOCKED"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  log "Verfuegbarkeit bestaetigt - kein Lauf gestartet"
  gate "AVAILABLE"
  exit 0
fi

[ -f "$AAB" ] || { log "AAB fehlt: $AAB"; gate "SKIPPED_NO_ARTIFACT"; exit 0; }

# ── Lauf nur, wenn ausdruecklich freigegeben ──────────────────
# Ohne explizite Freigabe wird kein Lauf gestartet, weil
# Test-Lab-Minuten auch im Spark-Kontingent knapp sind.
if [ "${NECTAR_ALLOW_FIREBASE_RUN:-0}" != "1" ]; then
  log "Kein Start ohne ausdrueckliche Freigabe"
  log "Setze NECTAR_ALLOW_FIREBASE_RUN=1, um den Spark-Lauf zu erlauben"
  gate "SKIPPED_NOT_AUTHORIZED"
  exit 0
fi

log "Starte Test Lab Spark-Lauf fuer ${APP}"
OUT=$(gcloud beta firebase test android run \
        --project="$PROJEKT" \
        --app "$AAB" \
        --device "spark.phone" \
        --timeout 30m \
        --format=json 2>&1)

if echo "$OUT" | grep -qiE "quota|limit|exceed"; then
  log "Kostenloses Kontingent erschoepft - KEIN Bezahlpfad"
  gate "WAITING_FOR_NO_COST_QUOTA"
elif echo "$OUT" | grep -qi "billing"; then
  log "Test Lab verlangt eine Zahlungsmethode - STOPP"
  gate "ZERO_COST_BLOCKED"
else
  log "$OUT" | tail -3
  gate "PASS"
fi
