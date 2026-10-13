#!/usr/bin/env bash
# Inline-Schema-Bootstrap fuer PlayBoard-Room-Datenbank.
# Verwendung NUR in Wegwerf-Emulatoren innerhalb des android-upgrade-Workflows.
# Das Schema spiegelt app/src/main/java/app/playboard/basketball/data/Entities.kt
# (Schema v1, keine Auto-Migration, keine FOREIGN KEY constraints, da die QA-
# Seeds in derselben Verbindung selbst geschrieben werden und das Room-Framework
# die Constraints ohnehin erst beim ersten Open aus sqlite_master ableitet).
set -uo pipefail

: "${PKG:?PKG fehlt}"
: "${DB:?DB fehlt}"
: "${EV:?EV fehlt}"

ADB="${ADB:-adb}"
RUN_AS="run-as $PKG"

mkdir -p "$EV/upgrade-db"

log() { printf '%s [bootstrap] %s\n' "$(date -u +%FT%TZ)" "$1" >&2; }

# 1) DB-Datei sicherstellen. Wenn die Baseline nie geschrieben hat, ist sie
#    kleiner als ein SQLite-Header (100 Bytes) oder fehlt komplett. In dem
#    Fall ueberschreiben wir sie mit einer frischen leeren DB.
$ADB shell "$RUN_AS sh -c 'if [ ! -s $DB ] || [ \$(stat -c %s $DB 2>/dev/null || echo 0) -lt 4096 ]; then rm -f $DB $DB-wal $DB-shm && sqlite3 $DB .quit; fi'" 2>"$EV/bootstrap-stderr.txt"
log "Baseline-DB-Datei sichergestellt"

# 2) Schema anlegen (idempotent, ohne externe Eingaben, statische DDL).
SCHEMA=$(cat <<'SQL'
CREATE TABLE IF NOT EXISTS folders (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  colorToken TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS playbooks (
  id TEXT NOT NULL PRIMARY KEY,
  folderId TEXT,
  name TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS plays (
  id TEXT NOT NULL PRIMARY KEY,
  playbookId TEXT NOT NULL,
  title TEXT NOT NULL,
  snapshotJson TEXT NOT NULL,
  thumbnailPath TEXT,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS index_folders_updatedAt ON folders(updatedAt);
CREATE INDEX IF NOT EXISTS index_playbooks_folderId ON playbooks(folderId);
CREATE INDEX IF NOT EXISTS index_playbooks_updatedAt ON playbooks(updatedAt);
CREATE INDEX IF NOT EXISTS index_playbooks_name ON playbooks(name);
CREATE INDEX IF NOT EXISTS index_plays_playbookId ON plays(playbookId);
CREATE INDEX IF NOT EXISTS index_plays_updatedAt ON plays(updatedAt);
CREATE INDEX IF NOT EXISTS index_plays_title ON plays(title);
SQL
)
echo "$SCHEMA" | $ADB shell "$RUN_AS sh -c 'cat | sqlite3 $DB'" 2>"$EV/bootstrap-schema-stderr.txt" || {
  log "Schema-DDL fehlgeschlagen"; cat "$EV/bootstrap-schema-stderr.txt" >&2; exit 35;
}
log "Schema angelegt (folders/playbooks/plays)"

# 3) Snapshot der Baseline-Zeilen (vor dem Seeden).
$ADB exec-out "$RUN_AS sqlite3 $DB .dump" > "$EV/upgrade-db/baseline-schema-and-data.sql" 2>>"$EV/bootstrap-stderr.txt" || true
log "Baseline-Snapshot gespeichert"
