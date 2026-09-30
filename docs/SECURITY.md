# Sicherheit

Dieses Repository ist **oeffentlich** und enthaelt ausschliesslich generische
Test-Infrastruktur. Es darf niemals privaten Produktcode, Signierzertifikate,
Passwoerter, API-Schluessel, Service-Account-JSON oder App-APKs enthalten.

## Invariante

> Privater Produktcode bleibt privat. Generische Test-Infrastruktur darf
> oeffentlich sein. Rechenleistung laeuft remote. Belege sind reproduzierbar.
> Abrechnung wird nie automatisch aktiviert.

## Was hier niemals hinein darf

| Verboten | Warum |
|---|---|
| App-Quellcode | Eigentuemerkommenschutz |
| `.jks`, `.keystore`, Signierpasswoerter | missbrauchbar fuer gefaelschte Apps |
| `.env` mit Schluesseln | oeffentlich sichtbar nach dem Push |
| Service-Account-JSON | vollstaendiger Cloud-Zugriff |
| APKs als langfristige Actions-Artefakte | oeffentlich downloadbar |
| Zeilen mit einem echten `build_id`-Pfad | macht Bruecke vorhersagbar |

## Wie die Privatsphaere gewahrt wird

1. Das Test-Farm klont **nie** ein privates App-Repository.
2. Der Workflow kennt nur eine **opake `build_id`** (UUID).
3. Das Artefakt liegt kurzzeitig auf der privaten Bridge (Contabo).
4. Der Runner laedt es ueber HTTPS mit einem Repository-Secret.
5. Der Secret-Wert, die authentifizierte URL und die Header werden
   **nie ausgegeben**.
6. Das Artefakt wird nach dem Lauf von der Bridge geloescht.

Der Brueckenpfad validiert die UUID-Struktur und lehnt Pfad-Traversal ab
(`scripts/fetch-artifact.sh`).

## Token- und Berechtigungsdisziplin

* `permissions: contents: read` in jedem Workflow.
* `GITHUB_TOKEN` wird nie an fremden Code uebergeben.
* Kein `pull_request_target` — dieser Workflow sieht Secrets von
  Pull-Requests an und wird deshalb nicht verwendet.
* Fremde Actions sind auf unveraenderliche Commit-SHAs gepinnt, nicht auf Tags.
* Jeder Job hat ein explizites `timeout-minutes`.
* Beleg-Artefakte werden nach 7 Tagen automatisch geloescht.

## Abrechnungsttor

Normale GitHub-gehostete Runner in oeffentlichen Repositories sind
kostenlos. Es wird **nie** automatisch eine Zahlungsmethode hinterlegt,
Blaze aktiviert oder ein kostenpflichtiger Runner gebucht.

Bricht ein Pfad ab, weil eine Zahlung noetig waere, lautet das Verdikt
`ZERO_COST_BLOCKED` — es wird kein Zahlungspfad eingeschlagen.

## Kontrollliste vor jedem Commit

```bash
# Keine Schluessel im Repository?
grep -rInE "sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN [A-Z ]*PRIVATE" . --exclude-dir=.git || echo "sauber"

# Keine Binaerdateien (APK, JKS)?
find . -type f \( -name "*.apk" -o -name "*.aab" -o -name "*.jks" -o -name "*.keystore" \) -not -path "./.git/*" || echo "sauber"

# Keine .env?
find . -name ".env*" -not -path "./.git/*" || echo "sauber"
```
