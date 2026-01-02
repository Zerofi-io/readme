#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  ZNode Update"
echo "============================================"
echo ""

INSTALL_DIR="/opt/znode"

# Check if ZNode is installed
if [ ! -d "$INSTALL_DIR" ] || [ ! -f "$INSTALL_DIR/.env" ]; then
  echo "ERROR: ZNode not found at $INSTALL_DIR"
  echo "Run the setup script first to install ZNode."
  exit 1
fi

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo ./update.sh)"
  exit 1
fi

cd "$INSTALL_DIR"

echo "Stopping ZNode..."
systemctl stop znode 2>/dev/null || true

echo "Updating docker-compose.yml..."
curl -fsSL "https://raw.githubusercontent.com/Zerofi-io/readme/main/docker-compose.yml?$(date +%s)" -o "$INSTALL_DIR/docker-compose.yml"

echo "Pulling latest images..."
docker compose pull

echo "Starting ZNode..."
systemctl start znode

echo ""
echo "============================================"
echo "  Update Complete!"
echo "============================================"
echo ""
echo "View logs: sudo journalctl -u znode -f"
