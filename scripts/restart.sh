#!/usr/bin/env bash
set -euo pipefail

# RecordRoom Restart
# Usage: ./scripts/restart.sh [service]
# Examples:
#   ./scripts/restart.sh           # restart all services
#   ./scripts/restart.sh frontend  # restart frontend only
#   ./scripts/restart.sh backend   # restart backend only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.onprem.yml"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
fatal() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ -f "$ENV_FILE" ] || fatal ".env not found. Run install.sh first."
source "$ENV_FILE"

if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    fatal "Docker Compose not found."
fi

PROFILES=""
if [ "${USE_BUILTIN_DB:-true}" = "true" ]; then
    PROFILES="--profile db"
fi

SERVICE="${1:-}"

cd "$PROJECT_DIR"

if [ -n "$SERVICE" ]; then
    info "Restarting ${SERVICE}..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES up -d --force-recreate "$SERVICE"
    ok "${SERVICE} restarted"
else
    info "Restarting all services..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES down
    $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES up -d
    ok "All services restarted"
fi

# Wait for healthy
info "Waiting for services to be healthy..."
for i in $(seq 1 60); do
    UNHEALTHY=$($COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES ps 2>&1 | grep -cE "starting|unhealthy" || true)
    if [ "$UNHEALTHY" = "0" ]; then
        break
    fi
    sleep 3
done

echo ""
exec "$SCRIPT_DIR/status.sh"
