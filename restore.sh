#!/usr/bin/env bash
#
# Restore an AffiNE backup created by ./backup.sh.
# Follows the official restore flow: stop the app so it can't write, safety-dump the
# CURRENT database first, then restore. Adapted for the named Postgres volume
# (recreated via `compose down -v`) and for Docker or rootless Podman.
#   https://docs.affine.pro/self-host-affine/administer/backup-and-restore
#
# Usage:
#   ./restore.sh <timestamp>            # e.g. ./restore.sh 20260611-140600
#   ./restore.sh /path/to/backup-dir
#   ENGINE=podman ./restore.sh <ts>     # force a runtime
#   FORCE=1 ./restore.sh <ts>           # skip the confirmation prompt
#
set -euo pipefail
cd "$(dirname "$0")"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!  \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: ./restore.sh <timestamp|backup-dir>"
[ -f .env ] || die "no .env in $(pwd) — run from the stack directory"

getenv() { grep -E "^$1=" .env | head -1 | cut -d= -f2- ; }
expand() { local p="$1"; p="${p/#\~/$HOME}"; p="${p//\$\{HOME\}/$HOME}"; p="${p//\$HOME/$HOME}"; printf '%s' "$p"; }

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/.affine/backups}"
ARG="$1"
if   [ -d "$ARG" ];               then SRC="$ARG"
elif [ -d "$BACKUP_ROOT/$ARG" ];  then SRC="$BACKUP_ROOT/$ARG"
else die "backup not found: '$ARG' (looked in $BACKUP_ROOT)"; fi
[ -f "$SRC/affine.backup" ] || die "no affine.backup in $SRC"

DB_USERNAME="$(getenv DB_USERNAME)";   DB_USERNAME="${DB_USERNAME:-affine}"
DB_DATABASE="$(getenv DB_DATABASE)";   DB_DATABASE="${DB_DATABASE:-affine}"
PORT="$(getenv PORT)";                 PORT="${PORT:-3010}"
UPLOAD_LOCATION="$(expand "$(getenv UPLOAD_LOCATION)")"
CONFIG_LOCATION="$(expand "$(getenv CONFIG_LOCATION)")"
PG_CONTAINER="affine_postgres"
TS="$(date +%Y%m%d%H%M%S)"

# --- detect runtime (stack may be down) ---
ENGINE="${ENGINE:-}"
if [ -z "$ENGINE" ]; then
  if   docker ps  --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then ENGINE=docker
  elif podman ps  --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then ENGINE=podman
  elif command -v docker >/dev/null 2>&1;                                       then ENGINE=docker
  else ENGINE=podman; fi
fi
COMPOSE="$ENGINE compose"
log "Runtime: $ENGINE   Source: $SRC"

# --- confirm (destructive) ---
if [ "${FORCE:-}" != 1 ]; then
  warn "This REPLACES the current database, uploads, and config under '$ENGINE' with this backup."
  read -rp "Type 'restore' to continue: " ans
  [ "$ans" = restore ] || die "aborted"
fi

# --- 1. safety-dump the current DB (if it's up) ---
if "$ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then
  SAFE="$BACKUP_ROOT/pre-restore-$TS"; mkdir -p "$SAFE"; chmod 700 "$SAFE"
  log "Safety-dumping current DB -> $SAFE/affine.backup"
  if "$ENGINE" exec "$PG_CONTAINER" pg_dump --format c --username "$DB_USERNAME" \
        --file /tmp/pre.backup "$DB_DATABASE" 2>/dev/null; then
    "$ENGINE" cp "$PG_CONTAINER":/tmp/pre.backup "$SAFE/affine.backup"
    "$ENGINE" exec "$PG_CONTAINER" rm -f /tmp/pre.backup
  else
    warn "safety dump failed (current DB may be empty/absent) — continuing"
  fi
fi

# --- 2. stop the stack and drop the Postgres volume, then start fresh ---
log "Stopping stack and recreating the Postgres volume…"
$COMPOSE down -v
log "Starting a fresh Postgres…"
$COMPOSE up -d postgres
log "Waiting for Postgres…"
until "$ENGINE" exec "$PG_CONTAINER" pg_isready -U "$DB_USERNAME" -d "$DB_DATABASE" >/dev/null 2>&1; do sleep 2; done

# --- 3. restore the database into the fresh, empty DB ---
log "Restoring database…"
"$ENGINE" cp "$SRC/affine.backup" "$PG_CONTAINER":/tmp/affine.backup
"$ENGINE" exec "$PG_CONTAINER" pg_restore --no-owner --username "$DB_USERNAME" \
  --dbname "$DB_DATABASE" --verbose /tmp/affine.backup
"$ENGINE" exec "$PG_CONTAINER" rm -f /tmp/affine.backup

# --- 4. restore uploads ---
if [ -f "$SRC/storage.tar.gz" ]; then
  log "Restoring uploads -> $UPLOAD_LOCATION"
  [ -d "$UPLOAD_LOCATION" ] && mv "$UPLOAD_LOCATION" "${UPLOAD_LOCATION}.before-restore.$TS"
  mkdir -p "$UPLOAD_LOCATION"; tar xzf "$SRC/storage.tar.gz" -C "$UPLOAD_LOCATION"
fi

# --- 5. restore config ---
if [ -f "$SRC/config.tar.gz" ]; then
  log "Restoring config -> $CONFIG_LOCATION"
  [ -d "$CONFIG_LOCATION" ] && mv "$CONFIG_LOCATION" "${CONFIG_LOCATION}.before-restore.$TS"
  mkdir -p "$CONFIG_LOCATION"; tar xzf "$SRC/config.tar.gz" -C "$CONFIG_LOCATION"
fi
[ -f "$SRC/env.backup" ] && warn "env.backup is NOT auto-applied (may hold another machine's secrets). Compare manually: $SRC/env.backup"

# --- 6. bring the full stack back up ---
log "Starting the full stack…"
$COMPOSE up -d

log "Restore complete. Verify at http://localhost:${PORT} — users, workspaces, docs, and uploads."
