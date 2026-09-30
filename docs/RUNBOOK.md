# Runbook

## Zweck

Ein Aufruf wie

```
Test WordGrid als Release-Kandidat.
```

soll Z Code ohne Kenntnis von GitHub Actions, ADB, Emulator oder Firebase
zu einem vertrauenswuerdigen Verdikt fuehren — **ohne lokalen Emulator
und ohne Rechnung**.

## Betriebsrealitaet: kein KVM

GitHub-gehostete Runner bieten **keine verschachtelte Virtualisierung**;
/dev/kvm ist dort nicht vorhanden. Der Emulator laeuft deshalb
zwingend in Software-Emulation (`-accel off`).

Folge: Der Boot dauert typischerweise **5 bis 15 Minuten**, nicht 30
Sekunden. `timeout-minutes` ist entsprechend grosszuehlig gewaehlt.
Das ist der Preis fuer 0 EUR — und die Alternative (Kontabo) hat
ebenfalls kein KVM.

## Artefakt-Bruecke

Die Bruecke nimmt Artefakte kurzfristig auf und liefert sie gegen eine
opake UUID plus Token. Sie laeuft auf dem Contabo-Server.

### Bruecke einrichten

Auf dem Server:

```bash
BRIDGE_ROOT=~/nectar-bridge
mkdir -p "$BRIDGE_ROOT/artifacts" "$BRIDGE_ROOT/keys"

# Token erzeugen
openssl rand -hex 32 > "$BRIDGE_ROOT/keys/token"
chmod 600 "$BRIDGE_ROOT/keys/token"
```

### Artefakt hochladen (aus der privaten Umgebung)

```bash
build_id=$(uuidgen | tr 'A-Z' 'a-z')
scp app-debug.apk hendler@62.84.189.144:~/nectar-bridge/artifacts/$build_id.apk
# 2. Bridge-Secret fuer das oeffentliche Repository setzen
#    (einmalig, per gh secret set BRIDGE_TOKEN ...)
```

Der Workflow sieht nur `build_id`. Der Pfad auf dem Server ist
`artifacts/<uuid>.apk` und damit nicht erratbar.

### Aufraeumen

Einraeumen **zwingend** nach jedem Lauf, sonst bleiben private APKs
unnoetig liegen:

```bash
find ~/nectar-bridge/artifacts -name "*.apk" -mmin +60 -delete
```

## Modi

| Modus | Matrix | Dauer ca. |
|---|---|---|
| `smoke` | 1 Geraet, aktuelle API | 15-20 min |
| `standard` | 3 Konfigurationen (untere API, aktuelle API, grosses Display) | 45-60 min |
| `release` | Phone, Tablet, Offline-Pfad, Zustandswiederherstellung, Asset-Pruefung | 60-75 min |

## Verdikt-Bedeutung

| Verdikt | Bedeutung |
|---|---|
| `PASS` | Angeforderte Matrix vollstaendig durchlaufen, alle Tore bestanden |
| `FAIL` | Reproduzierbarer App- oder Testdefekt |
| `INFRA_FAIL` | Runner, Emulator, Netz oder Werkzeug fehlgeschlagen — App ungeklaert |
| `ZERO_COST_BLOCKED` | Der naechste zulaessige Weg erfordert eine Zahlung |
| `WAITING_FOR_NO_COST_QUOTA` | Kostenloses Kontingent voruebergehend erschoepft |

**Ein Infrastrukturfehler wird nie als Produktdefekt gewertet. Fehlende
Belege ergeben nie PASS.**

## Abgrenzung

**Runtime-PASS ist kein Release-PASS.** Offen bleiben: Signierung,
Play-Richtlinien, Monetarisierung, Store-Eintrag, Datenschutzangabe
und Play-Rueckmeldung.

## Secrets-Inventar

| Name | Zweck | Wo |
|---|---|---|
| `BRIDGE_URL` | Basis-URL der privaten Bruecke | Repository-Secret |
| `BRIDGE_TOKEN` | Authentifizierung an der Bruecke | Repository-Secret |
| `FIREBASE_SERVICE_ACCOUNT` | optionaler Spark-Lauf | Repository-Secret, ungenutzt ohne Billing |

## Erste Schritte

```bash
gh workflow run android-smoke.yml \
  --repo hendlerdynasty-byte/nectar-android-test-farm \
  -f request_id="$(uuidgen | tr 'A-Z' 'a-z')" \
  -f app=example-app \
  -f package=com.example.app \
  -f build_id="<uuid>" \
  -f commit_sha="$(git rev-parse HEAD)" \
  -f artifact_name=app-debug.apk \
  -f artifact_sha256="$(shasum -a 256 app-debug.apk | awk '{print $1}')" \
  -f test_activity=com.example.app/.MainActivity
```
