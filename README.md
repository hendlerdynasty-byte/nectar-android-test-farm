# NECTAR Android Test-Farm

Generische, **oeffentliche** Test-Infrastruktur fuer Android-QA.
Sie ersetzt das lokale Starten eines Emulators auf Marius' Rechner.

Backend-Hierarchie (seit 30.09.2026):

1. **Firebase Test Lab** (`firebase-testlab.yml`) — bevorzugt. Robo/
   Instrumentation auf Google-Geräten, Minuten statt Stunden.
   Projekt `nectar-android-testlab-01`, Spark, kein Billing. Geräte werden
   **dynamisch** aus `gcloud firebase test android models list` gewählt,
   nie hart codiert; `preview`/`beta`/`deprecated` sind ausgeschlossen.
2. **Android-Software-Emulator** (`android-smoke/-matrix/-release`) —
   **nur Fallback** / Entwicklungsdiagnose, wenn Test Lab nicht erreichbar
   ist oder der Nutzer es ausdrücklich verlangt.

Zwei Zusagen:

1. **0 EUR.** Normale GitHub-Actions-Runner in oeffentlichen Repositories
   sind kostenlos; Test Lab laeuft im Spark-Plan im kostenlosen Tages-
   kontingent (10 virtuelle / 5 physische Laeufe pro Tag, Reset Mitternacht
   Pacific). Es wird nie eine Zahlungsmethode hinterlegt, nie Blaze aktiviert,
   und die Quote wird nie durch Konto-/Projekt-Rotation umgangen.
2. **Privatsphaere.** Hier steht kein Anwendungsquellcode, kein
   Signiermaterial, kein Schluessel und keine APK. Das Repository kennt
   ausschliesslich eine opake `build_id` und laedt das Artefakt von einer
   privaten Bruecke.

## Aufruf

Firebase Test Lab (bevorzugt):

```bash
gh workflow run firebase-testlab.yml \
  --repo hendlerdynasty-byte/nectar-android-test-farm \
  -f request_id="$(uuidgen | tr 'A-Z' 'a-z')" \
  -f app=meine-app -f package=com.beispiel.app -f mode=smoke \
  -f build_id="<uuid>" -f commit_sha="$(git rev-parse HEAD)" \
  -f artifact_name=app-release.apk \
  -f artifact_sha256="$(shasum -a 256 app-release.apk | awk '{print $1}')"
```

Benötigt das Repository-Secret `FIREBASE_TESTLAB_SA` (Dienstaccount
`nectar-testlab-ci`, Rolle `roles/cloudtestservice.testAdmin`, **kein**
Billing). Der Software-Emulator bleibt über die drei android-*-Workflows
verfügbar:

```bash
gh workflow run android-smoke.yml \
  --repo hendlerdynasty-byte/nectar-android-test-farm \
  -f request_id="$(uuidgen | tr 'A-Z' 'a-z')" \
  -f app=meine-app -f package=com.beispiel.app \
  -f build_id="<uuid>" -f commit_sha="$(git rev-parse HEAD)" \
  -f artifact_name=app-debug.apk \
  -f artifact_sha256="$(shasum -a 256 app-debug.apk | awk '{print $1}')"
```

## Modi

| Modus | Test Lab | Software-Emulator (Fallback) |
|---|---|---|
| `smoke` | 1 virtuelles Gerät (höchste stabile API ≤ targetSdk), Robo | 1 Gerät, Kaltstart, Absturzscan |
| `standard` | untere relevante API (minSdk) + aktuelle API + Tablet, Robo | 3 Konfigurationen, 60–90 min |
| `release` | Phone + Tablet + gezielt 1 physisches Gerät (wenn Tagesquote frei) | Phone, Tablet, Offline, Zustand, Assets |

## Ergebnis

`result.json` ist autoritativ. Das Test-Lab-Backend schreibt
`schema_version 2` (Superset; alle Felder des alten Schemas bleiben):

```json
{
  "schema_version": 2,
  "backend": "firebase-test-lab",
  "test_type": "robo|instrumentation",
  "firebase_matrix_id": "matrix-...",
  "devices": [{"model": "...", "version": "...", "state": "FINISHED", "outcome": "success"}],
  "verdict": "PASS|FAIL|INFRA_FAIL|ZERO_COST_BLOCKED|WAITING_FOR_NO_COST_QUOTA",
  "tests_passed": 0, "tests_failed": 0, "crashes": 0, "anrs": 0,
  "infra_failures": 0,
  "screenshots": 0, "robo_actions": 0, "robo_actions_success": 0,
  "evidence_dir": "..."
}
```

Ein Infrastrukturfehler wird **nie** als Produktdefekt gewertet.
Fehlende Belege ergeben **nie** PASS. Crashes/ANRs werden **nur dem
App-Paket** zugeordnet — Robo crawlt auch System-Apps, deren ANRs sind
Lärm (Befund TL-02 aus dem Governance-Setup 2026-09-28).

## Betriebsrealitaet

GitHub-Runner bieten keine verschachtelte Virtualisierung. Der
Fallback-Emulator laeuft in Software-Emulation und bootet deshalb
5 bis 15 Minuten. Details in `docs/RUNBOOK.md`.
Test-Lab-Laeufe dauern typischerweise 2–10 Minuten gesamt.

## Aufbau

```
.github/workflows/   firebase-testlab (bevorzugt), android-smoke / -matrix / -release (Fallback)
scripts/             fetch-artifact, firebase_run_and_collect, boot-emulator, run-smoke, normalize-result
schema/              test-request, test-result
docs/                RUNBOOK, SECURITY
```

## Abgrenzung

**Runtime-PASS ist kein Release-PASS.** Signierung, Play-Richtlinien,
Monetarisierung, Store-Eintrag, Datenschutzangabe und Play-Rueckmeldung
bleiben getrennte Tore. Eine temporäre Testinstallation beweist **nicht**
die Produktionssignatur.
