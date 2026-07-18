#!/usr/bin/env bash
#
# Back up the AffiNE self-host stack — Postgres (logical pg_dump, custom format),
# uploads (blobs), and config (+ .env). Follows the official guidance:
#   https://docs.affine.pro/self-host-affine/administer/backup-and-restore
#
# Works under Docker or rootless Podman (auto-detected). The stack must be running
# (Postgres up) so pg_dump can connect. Backups are written OUTSIDE the repo.
#
# Usage:
#   ./backup.sh                  # full backup -> ${BACKUP_ROOT:-~/.affine/backups}/<timestamp>
#   ./backup.sh --keep 14        # afterwards, prune all but the newest 14 backups
#   ENGINE=podman ./backup.sh    # force a runtime (otherwise auto-detected)
#
set -euo pipefail
cd "$(dirname "$0")"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!  \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP="${2:?--keep needs a number}"; shift 2;;
    -h|--help) sed -n '2,16p' "$0"; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

[ -f .env ] || die "no .env in $(pwd) — run from the stack directory"

getenv() { grep -E "^$1=" .env | head -1 | cut -d= -f2- ; }
# Expand ~, ${HOME} and $HOME in a path value read from .env
expand() { local p="$1"; p="${p/#\~/$HOME}"; p="${p//\$\{HOME\}/$HOME}"; p="${p//\$HOME/$HOME}"; printf '%s' "$p"; }

DB_USERNAME="$(getenv DB_USERNAME)";   DB_USERNAME="${DB_USERNAME:-affine}"
DB_DATABASE="$(getenv DB_DATABASE)";   DB_DATABASE="${DB_DATABASE:-affine}"
UPLOAD_LOCATION="$(expand "$(getenv UPLOAD_LOCATION)")"
CONFIG_LOCATION="$(expand "$(getenv CONFIG_LOCATION)")"
PG_CONTAINER="affine_postgres"

# --- detect runtime (must have Postgres running) ---
ENGINE="${ENGINE:-}"
if [ -z "$ENGINE" ]; then
  if   docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then ENGINE=docker
  elif podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then ENGINE=podman
  else die "Postgres container '$PG_CONTAINER' is not running under docker or podman — start the stack first."; fi
fi
"$ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER" \
  || die "Postgres container '$PG_CONTAINER' not running under $ENGINE."
log "Runtime: $ENGINE"

# --- backup target (outside the repo, per the docs) ---
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/.affine/backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$STAMP"
mkdir -p "$DEST"; chmod 700 "$BACKUP_ROOT" "$DEST" 2>/dev/null || true

# --- 1. Postgres: custom-format dump + integrity check ---
log "Dumping database '$DB_DATABASE'…"
"$ENGINE" exec "$PG_CONTAINER" pg_dump --format c --compress 9 \
  --username "$DB_USERNAME" --file /tmp/affine.backup "$DB_DATABASE"
"$ENGINE" exec "$PG_CONTAINER" pg_restore --list /tmp/affine.backup >/dev/null \
  || die "dump failed integrity check (pg_restore --list)"
"$ENGINE" cp "$PG_CONTAINER":/tmp/affine.backup "$DEST/affine.backup"
"$ENGINE" exec "$PG_CONTAINER" rm -f /tmp/affine.backup
log "  -> affine.backup ($(du -h "$DEST/affine.backup" | cut -f1))"

# --- 2. Uploads (filesystem blobs) ---
if [ -d "$UPLOAD_LOCATION" ]; then
  log "Archiving uploads ($UPLOAD_LOCATION)…"
  tar czf "$DEST/storage.tar.gz" -C "$UPLOAD_LOCATION" .
  log "  -> storage.tar.gz ($(du -h "$DEST/storage.tar.gz" | cut -f1))"
else
  warn "UPLOAD_LOCATION '$UPLOAD_LOCATION' not found — skipping (using S3 storage?)."
fi

# --- 3. Config (server config dir + .env) ---
if [ -d "$CONFIG_LOCATION" ]; then
  log "Archiving config ($CONFIG_LOCATION)…"
  tar czf "$DEST/config.tar.gz" -C "$CONFIG_LOCATION" .
fi
cp .env "$DEST/env.backup"; chmod 600 "$DEST/env.backup"

# --- manifest ---
cat > "$DEST/manifest.txt" <<EOF
AffiNE backup
created:  $STAMP
engine:   $ENGINE
database: $DB_DATABASE  (custom-format pg_dump -> affine.backup)
uploads:  $( [ -f "$DEST/storage.tar.gz" ] && echo storage.tar.gz || echo "(none / S3)" )
config:   $( [ -f "$DEST/config.tar.gz" ] && echo "config.tar.gz + env.backup" || echo env.backup )
restore:  ./restore.sh $STAMP
EOF

log "Backup complete -> $DEST"
ls -la "$DEST"

# --- optional retention ---
if [ "$KEEP" -gt 0 ]; then
  mapfile -t all < <(ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r)
  if [ "${#all[@]}" -gt "$KEEP" ]; then
    log "Pruning: keeping newest $KEEP of ${#all[@]} backups…"
    for old in "${all[@]:$KEEP}"; do warn "  removing $old"; rm -rf "${BACKUP_ROOT:?}/$old"; done
  fi
fi
