#!/usr/bin/env bash
set -euo pipefail

# RecordRoom On-Prem Bootstrap
# Usage: curl -sSL https://raw.githubusercontent.com/rishabhjain30/recordroom-onprem/main/bootstrap.sh | bash

GITHUB_REPO="rishabhjain30/recordroom-onprem"
INSTALL_DIR="${RECORDROOM_DIR:-/opt/recordroom}"
VERSION="${RECORDROOM_VERSION:-latest}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fatal() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  RecordRoom On-Prem Bootstrap${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

DOCKER_JUST_INSTALLED=false

# ---- Install Docker if missing ----
if command -v docker &>/dev/null; then
    ok "Docker found: $(docker --version 2>/dev/null | head -1)"
else
    info "Docker not found. Installing..."
    if curl -fsSL https://get.docker.com | sudo sh; then
        ok "Docker installed"
    else
        fatal "Docker installation failed. Install manually: https://docs.docker.com/engine/install/"
    fi
    sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
    sudo systemctl enable docker 2>/dev/null || true
    if ! groups | grep -q docker; then
        sudo usermod -aG docker "$USER"
        DOCKER_JUST_INSTALLED=true
    fi
fi

# ---- Install Docker Compose if missing ----
if command -v docker-compose &>/dev/null; then
    ok "Docker Compose found: $(docker-compose version 2>/dev/null | head -1)"
elif docker compose version &>/dev/null 2>&1; then
    ok "Docker Compose found: $(docker compose version 2>/dev/null | head -1)"
else
    info "Docker Compose not found. Installing..."
    COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
    if sudo curl -fsSL -o /usr/local/bin/docker-compose "$COMPOSE_URL" && sudo chmod +x /usr/local/bin/docker-compose; then
        ok "Docker Compose installed: $(docker-compose version 2>/dev/null | head -1)"
    else
        fatal "Docker Compose installation failed. Install manually: https://docs.docker.com/compose/install/"
    fi
fi

# ---- Install python3 if missing ----
if command -v python3 &>/dev/null; then
    ok "Python3 found"
else
    info "Python3 not found. Installing..."
    if command -v yum &>/dev/null; then
        sudo yum install -y python3 &>/dev/null
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y python3 &>/dev/null
    else
        fatal "Could not install python3. Install it manually and re-run."
    fi
    command -v python3 &>/dev/null || fatal "python3 installation failed."
    ok "Python3 installed"
fi

# ---- Resolve version ----
if [ "$VERSION" = "latest" ]; then
    info "Fetching latest release version..."
    VERSION=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | python3 -c "import sys,json; tag=json.load(sys.stdin)['tag_name']; print(tag.replace('onprem-v',''))" 2>/dev/null) || fatal "Could not determine latest version. Set RECORDROOM_VERSION explicitly."
fi
ok "Version: ${VERSION}"

# ---- Download release ----
RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/onprem-v${VERSION}/recordroom-onprem-v${VERSION}.tar.gz"
info "Downloading RecordRoom v${VERSION}..."

TARBALL="/tmp/recordroom-onprem-v${VERSION}.tar.gz"
curl -fsSL -o "$TARBALL" "$RELEASE_URL" || fatal "Download failed. Check that version ${VERSION} exists at:\n  ${RELEASE_URL}"

# ---- Extract ----
info "Installing to ${INSTALL_DIR}..."
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$(id -u):$(id -g)" "$INSTALL_DIR"
tar -xzf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1
rm -f "$TARBALL"
chmod +x "$INSTALL_DIR/scripts/"*.sh

ok "Files extracted to ${INSTALL_DIR}"

# ---- Print next steps ----
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  RecordRoom downloaded successfully!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

if [ "$DOCKER_JUST_INSTALLED" = "true" ]; then
    warn "Docker was just installed. You must log out and back in first"
    warn "for Docker permissions to take effect."
    echo ""
    echo "  Then run:"
    echo ""
    echo -e "    ${CYAN}cd ${INSTALL_DIR} && bash scripts/install.sh${NC}"
else
    echo "  To complete installation, run:"
    echo ""
    echo -e "    ${CYAN}cd ${INSTALL_DIR} && bash scripts/install.sh${NC}"
fi
echo ""
