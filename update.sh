#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  ZNode Update"
echo "============================================"
echo ""

INSTALL_DIR="/opt/znode"

REGISTRY_ADDR="0xcEa7f0871F289792538F327b82b0dfACDD7B503d"
STAKING_ADDR="0xd0fe0CAA7E4614DbB1BfEa94681e96Aa1680b0E1"
ZFI_ADDR="0xEEe2858E25dBd068FB4B0C9Fe517A68C7a6Ba619"
CONFIG_ADDR="0x6be7119726d0E90Bb2657EcA7691A8AF1aB70354"
BRIDGE_ADDR="0xdf628746E9607bfCA44D0372639b94653F079c60"

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

echo "Updating Monero daemon probe timeout..."
if grep -q 'MONERO_DAEMON_PROBE_TIMEOUT_MS' "$INSTALL_DIR/.env"; then
  sed -i 's/^MONERO_DAEMON_PROBE_TIMEOUT_MS=.*/MONERO_DAEMON_PROBE_TIMEOUT_MS=15000/' "$INSTALL_DIR/.env"
else
  echo 'MONERO_DAEMON_PROBE_TIMEOUT_MS=15000' >> "$INSTALL_DIR/.env"
fi

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
