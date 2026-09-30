#!/usr/bin/env bash
# Normalisiert die Laufergebnisse in das verbindliche JSON-Ergebnisformat.
#
# Die JSON-Ausgabe ist autoritativ. Eine begleitende SUMMARY.md ist
# nur fuer menschliche Leser gedacht.
set -euo pipefail

EV="${RUNNER_TEMP:-/tmp}/nectar-evidence"

: "${REQUEST_ID:?REQUEST_ID fehlt}"
: "${APP_ID:?APP_ID fehlt}"
: "${PACKAGE:?PACKAGE fehlt}"
: "${MODE:?MODE fehlt}"
: "${COMMIT_SHA:?COMMIT_SHA fehlt}"

MODE="${MODE}" MATRIX_JSON="${MATRIX_JSON:-[]}" \
ARTIFACT_SHA256="${ARTIFACT_SHA256:-}" \
VERSION_NAME="${VERSION_NAME:-unknown}" VERSION_CODE="${VERSION_CODE:-0}" \
TESTS_PASSED="${TESTS_PASSED:-0}" TESTS_FAILED="${TESTS_FAILED:-0}" \
CRASHES="${CRASH_COUNT:-0}" ANRS="${ANR_COUNT:-0}" \
INFRA_FAILURES="${INFRA_FAILURES:-0}" VERDICT="${VERDICT:-INFRA_FAIL}" \
BLOCKERS="${BLOCKERS:-}" \
EV="$EV" REQUEST_ID="$REQUEST_ID" APP_ID="$APP_ID" PACKAGE="$PACKAGE" \
COMMIT_SHA="$COMMIT_SHA" \
python3 - <<'PY'
import json, os, glob, datetime

ev = os.environ["EV"]

def count(pattern):
    total = 0
    for f in glob.glob(f"{ev}/logcat/*.txt") + glob.glob(f"{ev}/*.txt"):
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if pattern in line:
                        total += 1
        except OSError:
            pass
    return total

crashes = count("FATAL EXCEPTION") + count("am_crash")
anrs    = count("ANR in " + os.environ["PACKAGE"])

evidence = []
for p in sorted(glob.glob(f"{ev}/screenshots/*")):
    evidence.append({
        "type": "screenshot",
        "name": os.path.basename(p),
        "path": os.path.relpath(p, ev),
    })
for p in sorted(glob.glob(f"{ev}/logcat/*")):
    evidence.append({
        "type": "logcat",
        "name": os.path.basename(p),
        "path": os.path.relpath(p, ev),
    })

try:
    matrix = json.loads(os.environ.get("MATRIX_JSON") or "[]")
except json.JSONDecodeError:
    matrix = []

result = {
    "schema_version": 1,
    "request_id": os.environ["REQUEST_ID"],
    "app": os.environ["APP_ID"],
    "package": os.environ["PACKAGE"],
    "commit_sha": os.environ["COMMIT_SHA"],
    "artifact_sha256": os.environ.get("ARTIFACT_SHA256", ""),
    "version_name": os.environ.get("VERSION_NAME", "unknown"),
    "version_code": int(os.environ.get("VERSION_CODE") or 0),
    "mode": os.environ["MODE"],
    "matrix": matrix,
    "tests_passed": int(os.environ.get("TESTS_PASSED") or 0),
    "tests_failed": int(os.environ.get("TESTS_FAILED") or 0),
    "crashes": crashes,
    "anrs": anrs,
    "infra_failures": int(os.environ.get("INFRA_FAILURES") or 0),
    "verdict": os.environ.get("VERDICT", "INFRA_FAIL"),
    "blockers": [b for b in (os.environ.get("BLOCKERS") or "").split(";") if b],
    "evidence": evidence,
    "timestamp_utc": datetime.datetime.now(datetime.timezone.utc)
                     .strftime("%Y-%m-%dT%H:%M:%SZ"),
}

os.makedirs(ev, exist_ok=True)
with open(f"{ev}/result.json", "w", encoding="utf-8") as fh:
    json.dump(result, fh, indent=2, ensure_ascii=False)

lines = [
    f"# Ergebnis: {result['app']} ({result['mode']})",
    "",
    f"- **Verdikt:** `{result['verdict']}`",
    f"- **Paket:** `{result['package']}`",
    f"- **Commit:** `{result['commit_sha'][:12]}`",
    f"- **Artefakt-SHA256:** `{result['artifact_sha256'][:16]}...`",
    f"- **Tests:** {result['tests_passed']} bestanden, {result['tests_failed']} fehlgeschlagen",
    f"- **Crashes / ANRs:** {result['crashes']} / {result['anrs']}",
    f"- **Infrastrukturfehler:** {result['infra_failures']}",
    f"- **Anfrage:** `{result['request_id']}`",
    f"- **Zeitpunkt:** {result['timestamp_utc']}",
]
if result["blockers"]:
    lines += ["", "## Verbleibende Blockaden", ""] + [f"- {b}" for b in result["blockers"]]
lines += ["", f"Maschinenlesbar: `result.json`", ""]
with open(f"{ev}/SUMMARY.md", "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines))

print(f"result.json geschrieben: {result['verdict']}")
PY
