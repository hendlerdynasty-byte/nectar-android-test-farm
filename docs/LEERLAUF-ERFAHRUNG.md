# Betriebserfahrung: neun Fehler bis zum ersten grünen Lauf

Diese Liste entstand am 30.09.2026 beim ersten echten Durchlauf. Sie
spart der nächsten Person (oder KI) Stunden.

## 1. Erfundene Action-SHA

`uses: actions/upload-artifact@a5a2e3d4...` war frei erfunden.
Fehler: `unable to find version`.

**Regel:** SHAs immer gegen die GitHub-API prüfen, nie raten.

```bash
curl -s "https://api.github.com/repos/actions/upload-artifact/git/refs/tags/v4" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['object']['sha'])"
```

## 2. `actions/checkout` fehlte

Ohne Checkout liegt das Repository nicht im Workspace und jedes Skript
endet mit `No such file or directory` (Exit 127).

**Regel:** Jeder Workflow beginnt mit `actions/checkout`.

## 3. `shasum` gibt es auf Linux nicht

`sha256sum` gehört zu coreutils, `shasum` zu Perl. Auf dem Mac vorhanden,
auf dem Runner nicht.

**Regel:** Beide prüfen, `sha256sum` bevorzugen.

## 4. `sdkmanager` liegt nicht im PATH

Der Runner setzt `ANDROID_HOME`, aber nicht
`$ANDROID_HOME/cmdline-tools/latest/bin`.

**Regel:** Werkzeuge immer über absoluten Pfad oder eigene
Suchfunktion auflösen.

## 5. Das Image enthält keinen Emulator

`ubuntu-24.04` hat Build-Tools, Plattformen und Platform-Tools —
**keinen Emulator**. Er muss per `sdkmanager "emulator"` nachinstalliert
werden. Dauert 2–5 Minuten.

**Regel:** Nicht annehmen, dass etwas im Image liegt. Erst prüfen.

## 6. `ANDROID_AVD_HOME` nicht gesetzt

`avdmanager` legt die AVD an, der Emulator sucht sie woanders:
`Unknown AVD name [nectar-api34]`.

**Regel:** `ANDROID_AVD_HOME` vor `avdmanager` **und** `emulator` exportieren,
danach prüfen, dass die `.ini` wirklich liegt.

## 7. `adb` nicht im PATH

Nachfolgende Skripte scheitern mit `adb: command not found`, obwohl der
vorige Schritt adb erfolgreich über den absoluten Pfad gestartet hat.

**Regel:** Im Boot-Skript den Werkzeugpfad exportieren **und** in
Folge-Skripten selbst auflösen.

## 8. `sys.boot_completed` ist zu früh

Der Emulator meldet `sys.boot_completed=1`, bevor der Package-Manager
bereit ist. Jede Installation scheitert dann mit
`Can't find service: package`.

**Regel:** Auf `adb shell service check package` = `found` warten.

## 9. `set -e` mit adb ist eine Falle

`set -euo pipefail` bricht das Skript ab, sobald ein adb-Aufruf Exit 1
liefert. Das passiert ständig und gewöhnlich: Gerät noch nicht da,
Package-Manager noch nicht bereit, `grep -c` ohne Treffer.

**Regel:** Kein `set -e` in Skripten, die adb verwenden. Fehler einzeln
prüfen, am Ende mit `exit 0` beenden.

### Zusatz: `grep -c` gibt 0 aus UND Exit 1

```bash
CRASH=$(grep -c Muster datei || echo 0)    # ergibt "0\n0"!
CRASH=$(grep -c Muster datei | head -1)    # korrekt
```

Bei `set -o pipefail` bricht die Zuweisung sonst ab.

### Zusatz: `$GITHUB_ENV` gilt erst für den nächsten Schritt

```yaml
run: |
  echo "VERDICT=PASS" >> "$GITHUB_ENV"   # wirkt NICHT im selben Schritt
  ./skript.sh                            # sieht VERDICT nicht
```

Richtig: `VERDICT=PASS; export VERDICT; ./skript.sh`

## Betriebswerte (Software-Emulation, ohne KVM)

| Kennzahl | Wert |
|---|---|
| Emulator-Boot | 450–600 s |
| Package-Manager bereit | bis 300 s nach `sys.boot_completed` |
| Kaltstart der App | 20–35 s |
| Gesamtlauf smoke | ca. 23 min |

Das ist **normal** und kein Fehlerindikator. Wer unter 15 Minuten ein
Ergebnis erwartet, hat entweder Hardware-Beschleunigung oder einen
Fehler.
