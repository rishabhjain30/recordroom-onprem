#!/usr/bin/env bash
set -euo pipefail

# RecordRoom On-Prem Backup Script
# Usage: ./scripts/backup.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.onprem.yml"
BACKUP_DIR="$PROJECT_DIR/backups"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fatal() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ -f "$ENV_FILE" ] || fatal ".env file not found. Run install.sh first."
source "$ENV_FILE"

# Only backup built-in Postgres
if [ "${USE_BUILTIN_DB:-true}" != "true" ]; then
    warn "Using external database. Use your database provider's backup tools."
    warn "Connection: ${BACKEND_DATABASE_URL}"
    exit 0
fi

# Detect compose command
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    COMPOSE_CMD="docker compose"
fi

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/recordroom-${TIMESTAMP}.sql.gz"

info "Backing up database..."

# Get postgres container
PG_CONTAINER=$($COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile db ps -q postgres 2>/dev/null)
if [ -z "$PG_CONTAINER" ]; then
    fatal "Postgres container not found. Is it running?"
fi

# Dump and compress
docker exec "$PG_CONTAINER" pg_dump -U "${POSTGRES_USER:-postgres}" "${POSTGRES_DB:-recordroom}" | gzip > "$BACKUP_FILE"

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
ok "Backup saved: $BACKUP_FILE ($BACKUP_SIZE)"

# Rotate: keep last 7 daily backups
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/recordroom-*.sql.gz 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt 7 ]; then
    REMOVE_COUNT=$((BACKUP_COUNT - 7))
    ls -1t "$BACKUP_DIR"/recordroom-*.sql.gz | tail -n "$REMOVE_COUNT" | xargs rm -f
    info "Rotated: removed $REMOVE_COUNT old backup(s), keeping 7"
fi

echo ""
echo "Backups in $BACKUP_DIR:"
ls -lh "$BACKUP_DIR"/recordroom-*.sql.gz 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
echo ""
