#!/usr/bin/env bash
set -euo pipefail

# RecordRoom Status
# Usage: ./scripts/status.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.onprem.yml"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[ -f "$ENV_FILE" ] || { echo -e "${RED}[ERROR]${NC} .env not found. Run install.sh first."; exit 1; }
source "$ENV_FILE"

# Detect compose command
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    echo -e "${RED}[ERROR]${NC} Docker Compose not found."; exit 1
fi

PROFILES=""
if [ "${USE_BUILTIN_DB:-true}" = "true" ]; then
    PROFILES="--profile db"
fi

echo ""
echo -e "${CYAN}RecordRoom Status${NC}"
echo -e "${CYAN}==================${NC}"
echo ""

# Container status
$COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES ps 2>&1

echo ""

# Health checks
SITE="${SITE_URL:-http://localhost}"
if [ "${HTTP_PORT:-80}" != "80" ]; then
    SITE="http://localhost:${HTTP_PORT}"
fi

echo -e "${CYAN}Health Checks${NC}"
echo -e "${CYAN}-------------${NC}"

if curl -sf "${SITE}/health" >/dev/null 2>&1; then
    echo -e "  Backend API:   ${GREEN}healthy${NC}"
else
    echo -e "  Backend API:   ${RED}not responding${NC}"
fi

if curl -sf "${SITE}/auth/v1/health" >/dev/null 2>&1; then
    echo -e "  GoTrue Auth:   ${GREEN}healthy${NC}"
else
    echo -e "  GoTrue Auth:   ${RED}not responding${NC}"
fi

HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" "${SITE}/login" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo -e "  Frontend:      ${GREEN}healthy${NC}"
else
    echo -e "  Frontend:      ${RED}HTTP ${HTTP_CODE}${NC}"
fi

# Last backup
echo ""
echo -e "${CYAN}Backups${NC}"
echo -e "${CYAN}-------${NC}"
BACKUP_DIR="$PROJECT_DIR/backups"
if [ -d "$BACKUP_DIR" ] && ls "$BACKUP_DIR"/*.sql.gz &>/dev/null 2>&1; then
    LATEST=$(ls -t "$BACKUP_DIR"/*.sql.gz 2>/dev/null | head -1)
    LATEST_SIZE=$(du -h "$LATEST" | cut -f1)
    LATEST_NAME=$(basename "$LATEST")
    echo -e "  Latest: ${GREEN}${LATEST_NAME}${NC} (${LATEST_SIZE})"
    BACKUP_COUNT=$(ls "$BACKUP_DIR"/*.sql.gz 2>/dev/null | wc -l)
    echo -e "  Total:  ${BACKUP_COUNT} backup(s)"
else
    echo -e "  ${YELLOW}No backups found. Run: ./scripts/backup.sh${NC}"
fi

echo ""
