#!/usr/bin/env bash
set -euo pipefail

# RecordRoom On-Prem Restore Script
# Usage: ./scripts/restore.sh <backup-file.sql.gz>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.onprem.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fatal() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

BACKUP_FILE="${1:-}"
[ -z "$BACKUP_FILE" ] && fatal "Usage: $0 <backup-file.sql.gz>"
[ -f "$BACKUP_FILE" ] || fatal "Backup file not found: $BACKUP_FILE"
[ -f "$ENV_FILE" ] || fatal ".env file not found."

source "$ENV_FILE"

if [ "${USE_BUILTIN_DB:-true}" != "true" ]; then
    fatal "Restore only works with built-in Postgres. For external DB, use your provider's restore tools."
fi

if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    COMPOSE_CMD="docker compose"
fi

cd "$PROJECT_DIR"

echo ""
warn "This will REPLACE all current data with the backup."
read -rp "Are you sure? (yes/no): " CONFIRM
[ "$CONFIRM" = "yes" ] || { info "Cancelled."; exit 0; }

DB_NAME="${POSTGRES_DB:-recordroom}"
DB_USER="${POSTGRES_USER:-postgres}"

# Stop application services (keep postgres running)
info "Stopping application services..."
$COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile db stop nginx frontend backend gotrue 2>/dev/null || true

# Get postgres container
PG_CONTAINER=$($COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile db ps -q postgres)
[ -z "$PG_CONTAINER" ] && fatal "Postgres container not running."

# Drop and recreate database
info "Dropping and recreating database..."
docker exec "$PG_CONTAINER" psql -U "$DB_USER" -c "DROP DATABASE IF EXISTS ${DB_NAME};" postgres
docker exec "$PG_CONTAINER" psql -U "$DB_USER" -c "CREATE DATABASE ${DB_NAME};" postgres
docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "CREATE SCHEMA IF NOT EXISTS auth;"

# Restore
info "Restoring from $BACKUP_FILE..."
gunzip -c "$BACKUP_FILE" | docker exec -i "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" --quiet 2>&1 | tail -3

# Restart all services
info "Restarting all services..."
$COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile db up -d

# Wait for healthy
info "Waiting for services..."
sleep 15

echo ""
ok "Restore complete from: $BACKUP_FILE"
echo ""
