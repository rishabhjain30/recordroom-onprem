#!/usr/bin/env bash
set -euo pipefail

# RecordRoom Logs
# Usage: ./scripts/logs.sh [service] [-n lines]
# Examples:
#   ./scripts/logs.sh              # all services, last 100 lines, follow
#   ./scripts/logs.sh backend      # backend only
#   ./scripts/logs.sh -n 50        # last 50 lines
#   ./scripts/logs.sh backend -n 20

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.onprem.yml"

[ -f "$ENV_FILE" ] || { echo "[ERROR] .env not found. Run install.sh first."; exit 1; }
source "$ENV_FILE"

if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    echo "[ERROR] Docker Compose not found."; exit 1
fi

PROFILES=""
if [ "${USE_BUILTIN_DB:-true}" = "true" ]; then
    PROFILES="--profile db"
fi

# Parse arguments
LINES=100
SERVICE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n)
            LINES="$2"
            shift 2
            ;;
        *)
            SERVICE="$1"
            shift
            ;;
    esac
done

exec $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES logs --tail "$LINES" -f $SERVICE
