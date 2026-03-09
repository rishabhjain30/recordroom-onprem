#!/usr/bin/env bash
set -euo pipefail

# RecordRoom On-Prem Bootstrap
# Usage: curl -sSL https://raw.githubusercontent.com/rishabhjain30/recordroom-onprem/main/bootstrap.sh | bash

GITHUB_REPO="rishabhjain30/recordroom-onprem"
INSTALL_DIR="${RECORDROOM_DIR:-/opt/recordroom}"
VERSION="${RECORDROOM_VERSION:-latest}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
fatal() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  RecordRoom On-Prem Bootstrap${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# ---- Preflight ----
command -v docker &>/dev/null || fatal "Docker is not installed. Install Docker first: https://docs.docker.com/engine/install/"
command -v curl &>/dev/null || fatal "curl is not installed."
command -v python3 &>/dev/null || fatal "python3 is not installed."

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

# ---- Run installer ----
echo ""
info "Starting installer..."
echo ""

cd "$INSTALL_DIR"
exec bash scripts/install.sh
