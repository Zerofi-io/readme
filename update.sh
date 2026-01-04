#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  ZNode Update"
echo "============================================"
echo ""

INSTALL_DIR="/opt/znode"

REGISTRY_ADDR="0xC8de9d28F07d455443e2626897a4E6578cEd6dA2"
STAKING_ADDR="0x845C160B7fD0D2598e9860C022b53a0681a2977e"
ZFI_ADDR="0x3Dead1e93f08467fb4A15c3D3A5759d88d88833D"
CONFIG_ADDR="0x853BD67a8B9496b13D2C8b8696aeB54f5380f407"
BRIDGE_ADDR="0xC2Cb2B439c556E3f5Fd00Ca9705ce906aCf036d7"

if [ ! -d "$INSTALL_DIR" ] || [ ! -f "$INSTALL_DIR/.env" ]; then
  echo "ERROR: ZNode not found at $INSTALL_DIR"
  echo "Run the setup script first to install ZNode."
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo ./update.sh)"
  exit 1
fi

cd "$INSTALL_DIR"

echo "Stopping ZNode..."
systemctl stop znode 2>/dev/null || true

echo "Updating docker-compose.yml..."
curl -fsSL "https://raw.githubusercontent.com/Zerofi-io/readme/main/docker-compose.yml?$(date +%s)" -o "$INSTALL_DIR/docker-compose.yml"

echo "Updating contract addresses..."
sed -i \
  -e "s/^REGISTRY_ADDR=.*/REGISTRY_ADDR=$REGISTRY_ADDR/" \
  -e "s/^STAKING_ADDR=.*/STAKING_ADDR=$STAKING_ADDR/" \
  -e "s/^ZFI_ADDR=.*/ZFI_ADDR=$ZFI_ADDR/" \
  -e "s/^CONFIG_ADDR=.*/CONFIG_ADDR=$CONFIG_ADDR/" \
  -e "s/^BRIDGE_ADDR=.*/BRIDGE_ADDR=$BRIDGE_ADDR/" \
  "$INSTALL_DIR/.env"

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
