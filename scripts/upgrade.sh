#!/usr/bin/env bash
set -euo pipefail

# RecordRoom On-Prem Upgrade Script
# Usage: ./scripts/upgrade.sh [version]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.onprem.yml"
GITHUB_REPO="rishabhjain30/recordroom-onprem"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }
fatal() { err "$1"; exit 1; }

# Check .env exists
[ -f "$ENV_FILE" ] || fatal ".env file not found. Run install.sh first."

# Source env for compose command detection
source "$ENV_FILE"

# Detect compose command
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    fatal "Docker Compose not found."
fi

# Determine compose profiles
PROFILES=""
if [ "${USE_BUILTIN_DB:-true}" = "true" ]; then
    PROFILES="--profile db"
fi

NEW_VERSION="${1:-}"
if [ -z "$NEW_VERSION" ]; then
    read -rp "New version to upgrade to (e.g. 1.2.0): " NEW_VERSION
fi
[ -z "$NEW_VERSION" ] && fatal "Version is required."

cd "$PROJECT_DIR"

echo ""
echo -e "${CYAN}Upgrading RecordRoom to version ${NEW_VERSION}...${NC}"
echo ""

# Step 1: Backup
info "Step 1/6: Creating backup..."
if [ "${USE_BUILTIN_DB:-true}" = "true" ]; then
    "$SCRIPT_DIR/backup.sh" || warn "Backup failed — continuing anyway. Ctrl+C to abort."
else
    info "External database — skipping Docker backup. Ensure you have a recent backup."
fi

# Step 2: Record current state
info "Step 2/6: Recording current state..."
CURRENT_BACKEND=$(docker inspect --format='{{.Config.Image}}' "$($COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES ps -q backend 2>/dev/null)" 2>/dev/null || echo "unknown")
CURRENT_FRONTEND=$(docker inspect --format='{{.Config.Image}}' "$($COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES ps -q frontend 2>/dev/null)" 2>/dev/null || echo "unknown")
PREVIOUS_VERSION="${VERSION:-latest}"
ok "Current backend:  $CURRENT_BACKEND"
ok "Current frontend: $CURRENT_FRONTEND"

# Step 3: Download new deployment files
info "Step 3/6: Downloading deployment files for v${NEW_VERSION}..."
RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/onprem-v${NEW_VERSION}/recordroom-onprem-v${NEW_VERSION}.tar.gz"
TARBALL="/tmp/recordroom-onprem-v${NEW_VERSION}.tar.gz"

if curl -fsSL -o "$TARBALL" "$RELEASE_URL"; then
    # Extract and overwrite deployment files (preserves .env and backups)
    tar -xzf "$TARBALL" -C "$PROJECT_DIR" --strip-components=1
    rm -f "$TARBALL"
    ok "Deployment files updated"
else
    warn "Could not download release tarball. Using existing deployment files."
fi

# Step 4: Pull new images
info "Step 4/6: Pulling new images (version: ${NEW_VERSION})..."
# Update VERSION in .env
sed -i "s/^VERSION=.*/VERSION=\"${NEW_VERSION}\"/" "$ENV_FILE"

docker pull "ghcr.io/rishabhjain30/recordroom-backend:${NEW_VERSION}" 2>&1 | tail -3
docker pull "ghcr.io/rishabhjain30/recordroom-frontend:${NEW_VERSION}" 2>&1 | tail -3
ok "New images pulled"

# Step 5: Run migrations
info "Step 5/6: Running database migrations..."
$COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile setup $PROFILES run --rm migrate 2>&1 | grep -E "Running upgrade|Context impl|No new" || true
ok "Migrations complete"

# Step 6: Restart services
info "Step 6/6: Restarting services..."
$COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES up -d backend frontend
ok "Services restarting"

# Wait for healthy
info "Waiting for services to be healthy..."
for i in $(seq 1 60); do
    UNHEALTHY=$($COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES ps 2>&1 | grep -cE "starting|unhealthy" || true)
    if [ "$UNHEALTHY" = "0" ]; then
        break
    fi
    sleep 3
done

# Health check
SITE="${SITE_URL:-http://localhost}"
if [ "${HTTP_PORT:-80}" != "80" ]; then
    SITE="http://localhost:${HTTP_PORT}"
fi

if curl -sf "${SITE}/health" >/dev/null 2>&1; then
    ok "Backend healthy"
else
    err "Backend health check failed!"
    warn "Rolling back to previous version..."
    sed -i "s/^VERSION=.*/VERSION=\"${PREVIOUS_VERSION}\"/" "$ENV_FILE"
    $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES up -d backend frontend
    fatal "Upgrade failed. Rolled back to previous version."
fi

echo ""
echo -e "${GREEN}Upgrade to ${NEW_VERSION} complete!${NC}"
echo ""
