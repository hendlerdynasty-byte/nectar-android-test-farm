#!/usr/bin/env bash
# Verifiziert nach dem In-Place-Upgrade, dass die QA-Seed-Zeilen exakt
# erhalten sind. Verwendet NUR adb sqlite3, keine externen Eingaben.
set -uo pipefail

: "${PKG:?PKG fehlt}"
: "${DB:?DB fehlt}"
: "${EV:?EV fehlt}"

ADB="${ADB:-adb}"
RUN_AS="run-as $PKG"

log() { printf '%s [verify] %s\n' "$(date -u +%FT%TZ)" "$1" >&2; }

if [ ! -s "$EV/upgrade-db/expected-plays.tsv" ]; then
  log "Kein erwarteter Snapshot - Seed wurde uebersprungen"; exit 36;
fi

# Aktuelle Zeilen ziehen
$ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT id,playbookId,title,snapshotJson,IFNULL(thumbnailPath,\"\"),createdAt,updatedAt FROM plays WHERE id LIKE \"qa-upgrade-play-%\" ORDER BY id'" > "$EV/upgrade-db/actual-plays.tsv" 2>/dev/null
$ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT id,folderId,name,createdAt,updatedAt FROM playbooks WHERE id LIKE \"qa-upgrade-book-%\" ORDER BY id'" > "$EV/upgrade-db/actual-playbooks.tsv" 2>/dev/null
$ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT id,name,colorToken,createdAt,updatedAt FROM folders WHERE id=\"qa-upgrade-folder\"'" > "$EV/upgrade-db/actual-folders.tsv" 2>/dev/null

# Byte-genaue Diff: bei SQLite-TSV bedeutet das exakte Zeilenerhaltung inkl. JSON.
diff -u "$EV/upgrade-db/expected-plays.tsv" "$EV/upgrade-db/actual-plays.tsv" > "$EV/upgrade-db/diff-plays.txt" || DIFF_FAIL=1
diff -u "$EV/upgrade-db/expected-playbooks.tsv" "$EV/upgrade-db/actual-playbooks.tsv" > "$EV/upgrade-db/diff-playbooks.txt" || DIFF_FAIL=1
diff -u "$EV/upgrade-db/expected-folders.tsv" "$EV/upgrade-db/actual-folders.tsv" > "$EV/upgrade-db/diff-folders.txt" || DIFF_FAIL=1

PLAY_COUNT=$($ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT COUNT(*) FROM plays WHERE id LIKE \"qa-upgrade-play-%\"'" 2>/dev/null | tr -d '\r\n')
FOLDER_COUNT=$($ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT COUNT(*) FROM folders WHERE id=\"qa-upgrade-folder\"'" 2>/dev/null | tr -d '\r\n')
BOOK_COUNT=$($ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT COUNT(*) FROM playbooks WHERE id LIKE \"qa-upgrade-book-%\"'" 2>/dev/null | tr -d '\r\n')

log "Nach Upgrade: $PLAY_COUNT Plays, $BOOK_COUNT Playbooks, $FOLDER_COUNT Folder"

if [ -n "${DIFF_FAIL:-}" ] || [ "$PLAY_COUNT" != "10" ] || [ "$BOOK_COUNT" != "3" ] || [ "$FOLDER_COUNT" != "1" ]; then
  log "DATENDRIFT: Diff-Dateien in EV/upgrade-db/"
  cat "$EV/upgrade-db/diff-plays.txt" >&2 || true
  cat "$EV/upgrade-db/diff-playbooks.txt" >&2 || true
  cat "$EV/upgrade-db/diff-folders.txt" >&2 || true
  exit 37
fi

# Auch JSON-Inhalt pruefen: 10 Spieler pro Frame, 2 Frames pro Play.
BAD_JSON=$($ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT COUNT(*) FROM plays WHERE id LIKE \"qa-upgrade-play-%\" AND (LENGTH(snapshotJson) < 1000 OR snapshotJson NOT LIKE \"%frames%\" OR snapshotJson NOT LIKE \"%players%\")'" 2>/dev/null | tr -d '\r\n')
log "Plays mit unvollstaendigem JSON: $BAD_JSON"
[ "$BAD_JSON" = "0" ] || { log "JSON-Inhalt beschaedigt"; exit 38; }

log "PASS: alle 10 Plays + 3 Playbooks + 1 Folder byte-identisch nach In-Place-Upgrade"
