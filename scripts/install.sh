#!/usr/bin/env bash
set -euo pipefail

# RecordRoom On-Prem Installer
# Usage: ./scripts/install.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.onprem.yml"

# Colors
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

header() {
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}  RecordRoom On-Prem Installer${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
}

# ---- Preflight checks ----
preflight() {
    info "Running preflight checks..."

    # Docker
    if ! command -v docker &>/dev/null; then
        fatal "Docker is not installed. Install Docker first: https://docs.docker.com/engine/install/"
    fi
    ok "Docker found: $(docker --version)"

    # Docker Compose
    if command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    elif docker compose version </dev/null &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    else
        fatal "Docker Compose is not installed."
    fi
    ok "Docker Compose found"

    # Disk space (need at least 2GB free)
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS df reports 512-byte blocks by default
        AVAIL_BLOCKS=$(df "$PROJECT_DIR" | tail -1 | awk '{print $4}')
        AVAIL_GB=$((AVAIL_BLOCKS / 2 / 1024 / 1024))
    else
        AVAIL_KB=$(df "$PROJECT_DIR" --output=avail | tail -1 | tr -d ' ')
        AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
    fi
    if [ "$AVAIL_GB" -lt 2 ]; then
        fatal "Not enough disk space. Need at least 2GB free, have ${AVAIL_GB}GB."
    fi
    ok "Disk space: ${AVAIL_GB}GB available"

    # Compose file exists
    if [ ! -f "$COMPOSE_FILE" ]; then
        fatal "docker-compose.onprem.yml not found at $COMPOSE_FILE"
    fi
    ok "Compose file found"

    echo ""
}

# ---- Generate secrets ----
generate_secret() {
    python3 -c "import secrets; print(secrets.token_hex($1))"
}

generate_jwt() {
    local secret="$1"
    local role="$2"
    python3 -c "
import hmac, hashlib, base64, json, time

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

header = b64url(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode())
now = int(time.time())
payload = b64url(json.dumps({'role': '$role', 'iss': 'supabase', 'iat': now, 'exp': now + 10*365*24*3600}).encode())
sig_input = f'{header}.{payload}'.encode()
sig = b64url(hmac.new(b'$secret', sig_input, hashlib.sha256).digest())
print(f'{header}.{payload}.{sig}')
"
}

# ---- Collect configuration ----
collect_config() {
    info "Collecting configuration..."
    echo ""

    # Domain
    read -rp "Domain (e.g. recordroom.yourcompany.com) [localhost]: " SITE_DOMAIN
    SITE_DOMAIN="${SITE_DOMAIN:-localhost}"
    if [ "$SITE_DOMAIN" = "localhost" ]; then
        SITE_URL="http://localhost"
    else
        SITE_URL="https://${SITE_DOMAIN}"
    fi

    # HTTP port
    if [ "$SITE_DOMAIN" = "localhost" ]; then
        read -rp "HTTP port [80]: " HTTP_PORT
        HTTP_PORT="${HTTP_PORT:-80}"
    else
        HTTP_PORT="80"
    fi

    echo ""

    # Database
    echo "Database setup:"
    echo "  1) Built-in Postgres (recommended for quick start)"
    echo "  2) External Postgres (RDS, Cloud SQL, existing server)"
    read -rp "Choose [1]: " DB_CHOICE
    DB_CHOICE="${DB_CHOICE:-1}"

    USE_BUILTIN_DB="true"

    if [ "$DB_CHOICE" = "2" ]; then
        USE_BUILTIN_DB="false"
        echo ""
        echo "Provide your PostgreSQL connection details."
        echo "The database must already exist. We'll create the 'auth' schema."
        echo ""
        read -rp "PostgreSQL host: " EXT_DB_HOST
        read -rp "PostgreSQL port [5432]: " EXT_DB_PORT
        EXT_DB_PORT="${EXT_DB_PORT:-5432}"
        read -rp "PostgreSQL database name [recordroom]: " EXT_DB_NAME
        EXT_DB_NAME="${EXT_DB_NAME:-recordroom}"
        read -rp "PostgreSQL username: " EXT_DB_USER
        read -rsp "PostgreSQL password: " EXT_DB_PASS
        echo ""
        read -rp "SSL mode (disable/require/verify-full) [require]: " EXT_DB_SSL
        EXT_DB_SSL="${EXT_DB_SSL:-require}"

        # Test connection
        info "Testing database connection..."
        if python3 -c "
import psycopg2
conn = psycopg2.connect(host='$EXT_DB_HOST', port=$EXT_DB_PORT, dbname='$EXT_DB_NAME', user='$EXT_DB_USER', password='$EXT_DB_PASS', sslmode='$EXT_DB_SSL')
conn.close()
" 2>/dev/null; then
            ok "Database connection successful"
        else
            # Try without psycopg2 — just warn
            warn "Could not verify database connection (psycopg2 not installed locally). Continuing..."
        fi
    else
        POSTGRES_PASSWORD=$(generate_secret 16)
        ok "Built-in Postgres selected"
    fi

    echo ""

    # OpenAI API Key
    read -rp "OpenAI API key: " OPENAI_API_KEY
    if [ -z "$OPENAI_API_KEY" ]; then
        fatal "OpenAI API key is required."
    fi

    echo ""

    # Admin user
    info "Create admin account:"
    read -rp "Admin email: " ADMIN_EMAIL
    read -rsp "Admin password (min 8 chars): " ADMIN_PASSWORD
    echo ""
    read -rp "Admin full name: " ADMIN_NAME

    echo ""
}

# ---- Write .env file ----
write_env() {
    info "Generating secrets and writing .env..."

    JWT_SECRET=$(generate_secret 32)
    ANON_KEY=$(generate_jwt "$JWT_SECRET" "anon")
    SERVICE_ROLE_KEY=$(generate_jwt "$JWT_SECRET" "service_role")
    SECRET_KEY=$(generate_secret 32)

    if [ "$USE_BUILTIN_DB" = "true" ]; then
        GOTRUE_DATABASE_URL="postgres://postgres:${POSTGRES_PASSWORD}@postgres:5432/recordroom?sslmode=disable&search_path=auth"
        BACKEND_DATABASE_URL="postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/recordroom"
    else
        GOTRUE_DATABASE_URL="postgres://${EXT_DB_USER}:${EXT_DB_PASS}@${EXT_DB_HOST}:${EXT_DB_PORT}/${EXT_DB_NAME}?sslmode=${EXT_DB_SSL}&search_path=auth"
        BACKEND_DATABASE_URL="postgresql://${EXT_DB_USER}:${EXT_DB_PASS}@${EXT_DB_HOST}:${EXT_DB_PORT}/${EXT_DB_NAME}?sslmode=${EXT_DB_SSL}"
    fi

    cat > "$ENV_FILE" <<EOF
# RecordRoom On-Prem Configuration
# Generated by install.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Domain
SITE_URL="${SITE_URL}"
HTTP_PORT="${HTTP_PORT}"

# Database mode
USE_BUILTIN_DB="${USE_BUILTIN_DB}"

# Database URLs (GoTrue needs postgres://, backend needs postgresql://)
GOTRUE_DATABASE_URL="${GOTRUE_DATABASE_URL}"
BACKEND_DATABASE_URL="${BACKEND_DATABASE_URL}"

# Built-in Postgres credentials (ignored if using external DB)
POSTGRES_DB="recordroom"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-unused}"

# JWT (shared between GoTrue and backend)
JWT_SECRET="${JWT_SECRET}"
ANON_KEY="${ANON_KEY}"
SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY}"

# Backend
SECRET_KEY="${SECRET_KEY}"
OPENAI_API_KEY="${OPENAI_API_KEY}"

# Admin user (used by seed script)
ADMIN_EMAIL="${ADMIN_EMAIL}"
ADMIN_PASSWORD="${ADMIN_PASSWORD}"
ADMIN_NAME="${ADMIN_NAME}"

# Version
VERSION="latest"

# Email (optional — configure for invitations)
# RESEND_API_KEY=
# SMTP_HOST=
# SMTP_PORT=587
# SMTP_USER=
# SMTP_PASSWORD=
# SMTP_FROM=
EOF

    chmod 600 "$ENV_FILE"
    ok "Configuration written to .env"
}

# ---- Create auth schema on external DB ----
init_external_db() {
    if [ "$USE_BUILTIN_DB" = "false" ]; then
        info "Creating auth schema on external database..."
        python3 -c "
import psycopg2
conn = psycopg2.connect(
    host='$EXT_DB_HOST', port=$EXT_DB_PORT,
    dbname='$EXT_DB_NAME', user='$EXT_DB_USER',
    password='$EXT_DB_PASS', sslmode='$EXT_DB_SSL'
)
conn.autocommit = True
cur = conn.cursor()
cur.execute('CREATE SCHEMA IF NOT EXISTS auth')
cur.close()
conn.close()
print('Done')
" 2>/dev/null && ok "Auth schema created" || warn "Could not create auth schema automatically. Please run: CREATE SCHEMA IF NOT EXISTS auth;"
    fi
}

# ---- Start services ----
start_services() {
    cd "$PROJECT_DIR"

    # Determine compose profiles
    PROFILES=""
    if [ "$USE_BUILTIN_DB" = "true" ]; then
        PROFILES="--profile db"
    fi

    # Pull images (skip errors for locally-built images)
    info "Pulling Docker images..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES pull 2>&1 | tail -5 || warn "Some images could not be pulled (using local images)"

    # Start database first if built-in
    if [ "$USE_BUILTIN_DB" = "true" ]; then
        info "Starting built-in Postgres..."
        $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES up -d postgres
        info "Waiting for Postgres to be ready..."
        sleep 5
        PG_READY=false
        for i in $(seq 1 30); do
            if $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES ps postgres 2>&1 | grep -q "healthy"; then
                PG_READY=true
                break
            fi
            sleep 2
        done
        if [ "$PG_READY" = "true" ]; then
            ok "Postgres is ready"
        else
            fatal "Postgres failed to become healthy within 60s. Check: $COMPOSE_CMD -f $COMPOSE_FILE logs postgres"
        fi
    fi

    # Start GoTrue (needs DB)
    info "Starting GoTrue auth server..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES up -d gotrue
    info "Waiting for GoTrue to be ready..."
    GOTRUE_READY=false
    for i in $(seq 1 30); do
        if $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES ps gotrue 2>&1 | grep -q "healthy"; then
            GOTRUE_READY=true
            break
        fi
        sleep 2
    done
    if [ "$GOTRUE_READY" = "true" ]; then
        ok "GoTrue is ready"
    else
        fatal "GoTrue failed to become healthy within 60s. Check: $COMPOSE_CMD -f $COMPOSE_FILE logs gotrue"
    fi

    # Run migrations
    info "Running database migrations..."
    if $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile setup $PROFILES run --rm migrate 2>&1 | tee /tmp/rr-migrate.log | grep -E "Running upgrade|Context impl|No new" || true; then
        if grep -qi "error\|traceback\|failed" /tmp/rr-migrate.log 2>/dev/null; then
            err "Migration errors detected:"
            grep -i "error\|traceback\|failed" /tmp/rr-migrate.log | head -5
            fatal "Database migration failed. Check full log: /tmp/rr-migrate.log"
        fi
    fi
    rm -f /tmp/rr-migrate.log
    ok "Migrations complete"

    # Create admin user via GoTrue admin API (using docker exec since port isn't exposed)
    info "Creating admin user..."
    GOTRUE_CONTAINER=$($COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES ps -q gotrue)
    if [ -z "$GOTRUE_CONTAINER" ]; then
        warn "GoTrue container not found. Skipping admin creation — sign up at the login page."
    else
        ADMIN_BODY=$(python3 -c "
import json
print(json.dumps({
    'email': '''${ADMIN_EMAIL}''',
    'password': '''${ADMIN_PASSWORD}''',
    'email_confirm': True,
    'user_metadata': {'full_name': '''${ADMIN_NAME}'''}
}))
")
        ADMIN_RESULT=$(docker exec "$GOTRUE_CONTAINER" \
            wget -q -O- --post-data "$ADMIN_BODY" \
            --header "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
            --header "Content-Type: application/json" \
            "http://localhost:9999/admin/users" 2>&1) || true

        if echo "$ADMIN_RESULT" | grep -q '"email"'; then
            ok "Admin user created: ${ADMIN_EMAIL}"
        elif echo "$ADMIN_RESULT" | grep -qi 'already'; then
            ok "Admin user already exists: ${ADMIN_EMAIL}"
        else
            warn "Could not create admin user: $ADMIN_RESULT"
            warn "You can sign up at the login page instead."
        fi
    fi

    # Start remaining services
    info "Starting backend, frontend, and nginx..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES up -d
    ok "All services starting"

    # Wait for everything to be healthy
    info "Waiting for all services to be healthy..."
    for i in $(seq 1 60); do
        UNHEALTHY=$($COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROFILES ps 2>&1 | grep -c "starting\|unhealthy" || true)
        if [ "$UNHEALTHY" = "0" ]; then
            break
        fi
        sleep 3
    done
}

# ---- Health check ----
health_check() {
    echo ""
    info "Running health checks..."

    SITE="${SITE_URL}"
    if [ "$SITE_DOMAIN" = "localhost" ] && [ "$HTTP_PORT" != "80" ]; then
        SITE="http://localhost:${HTTP_PORT}"
    fi

    # Backend health
    if curl -sf "${SITE}/health" >/dev/null 2>&1; then
        ok "Backend API: healthy"
    else
        warn "Backend API: not responding yet (may still be starting)"
    fi

    # GoTrue health
    if curl -sf "${SITE}/auth/v1/health" >/dev/null 2>&1; then
        ok "GoTrue auth: healthy"
    else
        warn "GoTrue auth: not responding yet"
    fi

    # Frontend
    HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" "${SITE}/login" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        ok "Frontend: healthy"
    else
        warn "Frontend: HTTP ${HTTP_CODE} (may still be starting)"
    fi
}

# ---- Print summary ----
print_summary() {
    SITE="${SITE_URL}"
    if [ "$SITE_DOMAIN" = "localhost" ] && [ "$HTTP_PORT" != "80" ]; then
        SITE="http://localhost:${HTTP_PORT}"
    fi

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  RecordRoom installed successfully!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "  URL:          ${CYAN}${SITE}${NC}"
    echo -e "  Admin email:  ${CYAN}${ADMIN_EMAIL}${NC}"
    echo -e "  Admin pass:   ${CYAN}(as entered during setup)${NC}"
    echo ""
    echo "  Useful commands:"
    echo "    View logs:     $COMPOSE_CMD -f docker-compose.onprem.yml --env-file .env logs -f"
    echo "    Stop:          $COMPOSE_CMD -f docker-compose.onprem.yml --env-file .env down"
    echo "    Restart:       $COMPOSE_CMD -f docker-compose.onprem.yml --env-file .env up -d"
    echo "    Backup:        ./scripts/backup.sh"
    echo "    Upgrade:       ./scripts/upgrade.sh"
    echo ""
    if [ "$USE_BUILTIN_DB" = "true" ]; then
        echo -e "  ${YELLOW}Database: Built-in Postgres (data stored in Docker volume 'pgdata')${NC}"
    else
        echo -e "  ${YELLOW}Database: External (${EXT_DB_HOST}:${EXT_DB_PORT}/${EXT_DB_NAME})${NC}"
    fi
    echo ""
}

# ---- Main ----
main() {
    header
    preflight
    collect_config
    write_env
    init_external_db
    start_services
    health_check
    print_summary
}

main "$@"
