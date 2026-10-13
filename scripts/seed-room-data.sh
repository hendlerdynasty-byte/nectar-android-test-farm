#!/usr/bin/env bash
# Schreibt die QA-Regression-Seed-Zeilen direkt via adb sqlite3 in die
# Room-DB des Emulators. Verwendet NUR statische Werte, keine externen
# Eingaben, parameterisierte Inserts ueber sqlite3 .parameter set.
set -uo pipefail

: "${PKG:?PKG fehlt}"
: "${DB:?DB fehlt}"
: "${EV:?EV fehlt}"

ADB="${ADB:-adb}"
RUN_AS="run-as $PKG"

log() { printf '%s [seed] %s\n' "$(date -u +%FT%TZ)" "$1" >&2; }

# Snapshot-Generator: deterministisches JSON mit fester Spieler-Anordnung.
snapshot_sql() {
  local i="$1"
  cat <<JSON
'{"version":1,"courtPreset":"HALF_COURT","frames":[{"players":[{"id":"home_1","team":"HOME","number":1,"label":"H1","position":{"x":0.20,"y":0.26},"colorToken":"home_navy"},{"id":"home_2","team":"HOME","number":2,"label":"H2","position":{"x":0.20,"y":0.42},"colorToken":"home_navy"},{"id":"home_3","team":"HOME","number":3,"label":"H3","position":{"x":0.20,"y":0.58},"colorToken":"home_navy"},{"id":"home_4","team":"HOME","number":4,"label":"H4","position":{"x":0.20,"y":0.74},"colorToken":"home_navy"},{"id":"home_5","team":"HOME","number":5,"label":"H5","position":{"x":0.20,"y":0.90},"colorToken":"home_navy"},{"id":"away_1","team":"AWAY","number":1,"label":"A1","position":{"x":0.75,"y":0.26},"colorToken":"away_gold"},{"id":"away_2","team":"AWAY","number":2,"label":"A2","position":{"x":0.75,"y":0.42},"colorToken":"away_gold"},{"id":"away_3","team":"AWAY","number":3,"label":"A3","position":{"x":0.75,"y":0.58},"colorToken":"away_gold"},{"id":"away_4","team":"AWAY","number":4,"label":"A4","position":{"x":0.75,"y":0.74},"colorToken":"away_gold"},{"id":"away_5","team":"AWAY","number":5,"label":"A5","position":{"x":0.75,"y":0.90},"colorToken":"away_gold"}],"ball":{"position":{"x":0.20,"y":0.50}},"strokes":[{"id":"marker-arrow-0","type":"ARROW","points":[{"x":0.2,"y":0.5},{"x":0.5,"y":0.5}],"colorToken":"line_white","strokeWidth":0.009}]},{"players":[{"id":"home_1","team":"HOME","number":1,"label":"H1","position":{"x":0.28,"y":0.26},"colorToken":"home_navy"},{"id":"home_2","team":"HOME","number":2,"label":"H2","position":{"x":0.28,"y":0.42},"colorToken":"home_navy"},{"id":"home_3","team":"HOME","number":3,"label":"H3","position":{"x":0.28,"y":0.58},"colorToken":"home_navy"},{"id":"home_4","team":"HOME","number":4,"label":"H4","position":{"x":0.28,"y":0.74},"colorToken":"home_navy"},{"id":"home_5","team":"HOME","number":5,"label":"H5","position":{"x":0.28,"y":0.90},"colorToken":"home_navy"},{"id":"away_1","team":"AWAY","number":1,"label":"A1","position":{"x":0.75,"y":0.26},"colorToken":"away_gold"},{"id":"away_2","team":"AWAY","number":2,"label":"A2","position":{"x":0.75,"y":0.42},"colorToken":"away_gold"},{"id":"away_3","team":"AWAY","number":3,"label":"A3","position":{"x":0.75,"y":0.58},"colorToken":"away_gold"},{"id":"away_4","team":"AWAY","number":4,"label":"A4","position":{"x":0.75,"y":0.74},"colorToken":"away_gold"},{"id":"away_5","team":"AWAY","number":5,"label":"A5","position":{"x":0.75,"y":0.90},"colorToken":"away_gold"}],"ball":{"position":{"x":0.28,"y":0.50}},"strokes":[{"id":"marker-arrow-1","type":"ARROW","points":[{"x":0.2,"y":0.5},{"x":0.5,"y":0.5}],"colorToken":"line_white","strokeWidth":0.009}]}],"activeFrameIndex":1,"teamSettings":{"homeColorToken":"home_navy","awayColorToken":"away_gold","lineColorToken":"line_white"}}'
JSON
}

# Seed-SQL als ein einziger Aufruf, damit die DB nicht zwischen den Inserts
# geschlossen wird. Snapshot-JSON kommt aus snapshot_sql().
SEED_SQL=$(cat <<'SQL'
.parameter init
.parameter set :folder_id 'qa-upgrade-folder'
.parameter set :folder_name 'QA training folder'
.parameter set :folder_token 'folder_court'
.parameter set :now 1791700000000
INSERT OR REPLACE INTO folders (id,name,colorToken,createdAt,updatedAt) VALUES (:folder_id,:folder_name,:folder_token,:now,:now);
SQL
)
for b in 0 1 2; do
  SEED_SQL+=$'\n.parameter set :book_id '"'qa-upgrade-book-$b'"$'\n.parameter set :book_name '"'QA Playbook $b'"$'\n.parameter set :ts '"$((1791700000000 + b))"$'\nINSERT OR REPLACE INTO playbooks (id,folderId,name,createdAt,updatedAt) VALUES (:book_id,:folder_id,:book_name,:ts,:ts);'
done
for i in 0 1 2 3 4 5 6 7 8 9; do
  book=$((i % 3))
  play_id=$(printf 'qa-upgrade-play-%02d' "$i")
  title=$(printf 'Before release play %02d' "$i")
  ts=$((1791700000000 + i))
  snap=$(snapshot_sql "$i")
  SEED_SQL+=$'\n.parameter set :play_id '"'${play_id}'"$'\n.parameter set :playbook_id '"'qa-upgrade-book-${book}'"$'\n.parameter set :title '"'${title}'"$'\n.parameter set :snap '"'${snap}'"$'\n.parameter set :ts '"${ts}"$'\nINSERT OR REPLACE INTO plays (id,playbookId,title,snapshotJson,thumbnailPath,createdAt,updatedAt) VALUES (:play_id,:playbook_id,:title,:snap,NULL,:ts,:ts);'
done

# Snapshot-Zaehler vor dem Schreiben
BEFORE_COUNT=$($ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT COUNT(*) FROM plays WHERE id LIKE \"qa-upgrade-play-%\"'" 2>/dev/null | tr -d '\r\n')
log "Plays vor Seed: $BEFORE_COUNT"

printf '%s\n' "$SEED_SQL" | $ADB shell "$RUN_AS sh -c 'cat | sqlite3 $DB'" 2>"$EV/seed-stderr.txt" || {
  log "Seed fehlgeschlagen"; cat "$EV/seed-stderr.txt" >&2; exit 33;
}

AFTER_COUNT=$($ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT COUNT(*) FROM plays WHERE id LIKE \"qa-upgrade-play-%\"'" 2>/dev/null | tr -d '\r\n')
FOLDER_COUNT=$($ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT COUNT(*) FROM folders WHERE id=\"qa-upgrade-folder\"'" 2>/dev/null | tr -d '\r\n')
BOOK_COUNT=$($ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT COUNT(*) FROM playbooks WHERE id LIKE \"qa-upgrade-book-%\"'" 2>/dev/null | tr -d '\r\n')
log "Plays nach Seed: $AFTER_COUNT (erwartet 10)"
log "Folders: $FOLDER_COUNT (erwartet 1)"
log "Playbooks: $BOOK_COUNT (erwartet 3)"

[ "$AFTER_COUNT" = "10" ] || { log "Seed fehlerhaft: nicht 10 Plays"; exit 33; }
[ "$FOLDER_COUNT" = "1" ] || { log "Seed fehlerhaft: nicht 1 Folder"; exit 33; }
[ "$BOOK_COUNT" = "3" ] || { log "Seed fehlerhaft: nicht 3 Playbooks"; exit 33; }

# Erwartungs-Snapshot in den Runner-Temp schreiben, damit verify ihn lesen kann
$ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT id,playbookId,title,snapshotJson,IFNULL(thumbnailPath,\"\"),createdAt,updatedAt FROM plays WHERE id LIKE \"qa-upgrade-play-%\" ORDER BY id'" > "$EV/upgrade-db/expected-plays.tsv" 2>/dev/null
$ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT id,folderId,name,createdAt,updatedAt FROM playbooks WHERE id LIKE \"qa-upgrade-book-%\" ORDER BY id'" > "$EV/upgrade-db/expected-playbooks.tsv" 2>/dev/null
$ADB exec-out "$RUN_AS sqlite3 $DB 'SELECT id,name,colorToken,createdAt,updatedAt FROM folders WHERE id=\"qa-upgrade-folder\"'" > "$EV/upgrade-db/expected-folders.tsv" 2>/dev/null

log "Seed abgeschlossen: 10 Plays + 3 Playbooks + 1 Folder"
