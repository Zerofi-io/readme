#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  ZNode v2.2.2 -> v2.2.3 Migration"
echo "============================================"
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo ./migrate.sh)"
  exit 1
fi

# Check for Docker
if ! command -v docker &> /dev/null; then
  echo "Docker not found. Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
fi

# Check for Docker Compose
if ! docker compose version &> /dev/null; then
  echo "Docker Compose not found. Installing..."
  apt-get update && apt-get install -y docker-compose-plugin
fi

echo ""
echo "=== Step 1: Stopping Current Services ==="
systemctl stop znode 2>/dev/null || true
systemctl stop cluster-aggregator 2>/dev/null || true
pkill -f monero-wallet-rpc 2>/dev/null || true
pkill -f "p2p-daemon" 2>/dev/null || true
sleep 2
echo "  Services stopped."

echo ""
echo "=== Step 2: Creating Data Directory ==="
mkdir -p /data/monero-wallets
mkdir -p /data/.znode-bridge
mkdir -p /data/.znode-backup
echo "  Directories created."

echo ""
echo "=== Step 3: Copying Wallet & State Data ==="

# Copy monero wallets
if [ -d "/root/.monero-wallets" ]; then
  cp -a /root/.monero-wallets/* /data/monero-wallets/ 2>/dev/null || true
  echo "  Copied monero wallets."
fi

# Copy bridge data from home
if [ -d "/root/.znode-bridge" ]; then
  cp -a /root/.znode-bridge/* /data/.znode-bridge/ 2>/dev/null || true
  echo "  Copied bridge data from ~/.znode-bridge"
fi

# Copy bridge data from v2.2.2 directory
if [ -d "/root/znodev2.2.2/.znode-bridge" ]; then
  cp -a /root/znodev2.2.2/.znode-bridge/* /data/.znode-bridge/ 2>/dev/null || true
  echo "  Copied bridge data from znodev2.2.2/.znode-bridge"
fi

# Copy backup data
if [ -d "/root/znodev2.2.2/.znode-backup" ]; then
  cp -a /root/znodev2.2.2/.znode-backup/* /data/.znode-backup/ 2>/dev/null || true
  echo "  Copied wallet backup data."
fi

# Copy state files
cp /root/znodev2.2.2/.cluster-state.json /data/ 2>/dev/null || true
cp /root/znodev2.2.2/.cluster-restore.json /data/ 2>/dev/null || true
cp /root/znodev2.2.2/.cluster-blacklist.json /data/ 2>/dev/null || true
cp /root/znodev2.2.2/.downtime-seen.json /data/ 2>/dev/null || true
cp /root/znodev2.2.2/.tx-state.json /data/ 2>/dev/null || true
echo "  Copied state files."

echo ""
echo "=== Step 4: Setting Up v2.2.3 ==="
mkdir -p /opt/znode

# Copy existing .env
cp /root/znodev2.2.2/.env /opt/znode/.env
chmod 600 /opt/znode/.env
echo "  Copied .env configuration."

# Download docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/Zerofi-io/readme/main/docker-compose.yml -o /opt/znode/docker-compose.yml

# Modify to use bind mount instead of volume
sed -i 's/- znode-data:\/data/- \/data:\/data/g' /opt/znode/docker-compose.yml
sed -i 's/- znode-tmp:\/tmp/- \/tmp:\/tmp/g' /opt/znode/docker-compose.yml
echo "  Downloaded and configured docker-compose.yml"

echo ""
echo "=== Step 5: Pulling Docker Images ==="
cd /opt/znode
docker compose pull

echo ""
echo "=== Step 6: Creating Systemd Service ==="

# Disable old service
systemctl disable znode 2>/dev/null || true
systemctl disable cluster-aggregator 2>/dev/null || true

# Create new systemd service
cat > /etc/systemd/system/znode.service << SERVICEEOF
[Unit]
Description=ZeroFi Node v2.2.3
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
WorkingDirectory=/opt/znode
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable znode.service
echo "  Systemd service created and enabled."

# Create helper scripts
cat > /opt/znode/start << 'STARTEOF'
#!/bin/bash
sudo systemctl start znode
echo "ZNode started. View logs with: sudo journalctl -u znode -f"
STARTEOF
chmod +x /opt/znode/start

cat > /opt/znode/stop << 'STOPEOF'
#!/bin/bash
sudo systemctl stop znode
echo "ZNode stopped."
STOPEOF
chmod +x /opt/znode/stop

cat > /opt/znode/logs << 'LOGSEOF'
#!/bin/bash
cd /opt/znode && docker compose logs -f
LOGSEOF
chmod +x /opt/znode/logs

echo ""
echo "=== Step 7: Starting ZNode v2.2.3 ==="
systemctl start znode

echo ""
echo "============================================"
echo "  Migration Complete!"
echo "============================================"
echo ""
echo "ZNode v2.2.3 is now running."
echo ""
echo "Your data has been preserved:"
echo "  - Monero wallets: /data/monero-wallets/"
echo "  - Bridge data: /data/.znode-bridge/"
echo "  - State files: /data/"
echo "  - Backups: /data/.znode-backup/"
echo ""
echo "Commands:"
echo "  Start:   sudo systemctl start znode"
echo "  Stop:    sudo systemctl stop znode"
echo "  Logs:    sudo journalctl -u znode -f"
echo "  Status:  sudo systemctl status znode"
echo ""
echo "Configuration: /opt/znode/.env"
echo ""
