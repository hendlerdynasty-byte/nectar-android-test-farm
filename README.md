# NECTAR Android Test-Farm

Generische, **oeffentliche** Test-Infrastruktur fuer Android-QA.
Sie ersetzt das lokale Starten eines Emulators auf Marius' Rechner.

Zwei Zusagen:

1. **0 EUR.** Normale GitHub-Actions-Runner in oeffentlichen Repositories
   sind kostenlos. Es wird nie eine Zahlungsmethode hinterlegt.
2. **Privatsphaere.** Hier steht kein Anwendungsquellcode, kein
   Signiermaterial, kein Schluessel und keine APK. Das Repository kennt
   ausschliesslich eine opake `build_id` und laedt das Artefakt von einer
   privaten Bruecke.

## Aufruf

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

| Modus | Was passiert |
|---|---|
| `smoke` | 1 Geraet, aktuelle API, Kaltstart, Absturzscan, Screenshots |
| `standard` | minSdk-kompatible untere API, verfuegbare obere API (37 wenn vorhanden), grosses Display; ein Bridge-Download |
| `release` | AAB-Installation, Phone, Tablet, Offline-Pfad, Prozessneustart, Asset-Pruefung |

## Ergebnis

`result.json` ist autoritativ:

```json
{
  "schema_version": 1,
  "verdict": "PASS|FAIL|INFRA_FAIL|ZERO_COST_BLOCKED|WAITING_FOR_NO_COST_QUOTA",
  "tests_passed": 0, "tests_failed": 0, "crashes": 0, "anrs": 0,
  "infra_failures": 0,
  "evidence": []
}
```

Ein Infrastrukturfehler wird **nie** als Produktdefekt gewertet.
Fehlende Belege ergeben **nie** PASS.

## Betriebsrealitaet: kein KVM

GitHub-Runner bieten keine verschachtelte Virtualisierung. Der Emulator
laeuft in Software-Emulation und bootet deshalb 5 bis 15 Minuten.
Details in `docs/RUNBOOK.md`.

## Aufbau

```
.github/workflows/   android-smoke / -matrix / -release
scripts/             fetch-artifact, boot-emulator, run-smoke, normalize-result
schema/              test-request, test-result
docs/                RUNBOOK, SECURITY
```

## Abgrenzung

**Runtime-PASS ist kein Release-PASS.** Signierung, Play-Richtlinien,
Monetarisierung, Store-Eintrag, Datenschutzangabe und Play-Rueckmeldung
bleiben getrennte Tore.
