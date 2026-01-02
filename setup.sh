#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  ZNode v2.2.3 Setup"
echo "============================================"
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo ./setup.sh)"
  exit 1
fi

# Check for Docker
if ! command -v docker &> /dev/null; then
  echo "Docker not found. Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  echo "Docker installed successfully."
fi

echo ""
echo "=== Required Configuration ==="
echo ""

# Get Ethereum private key
while true; do
  read -r -s -p "Ethereum private key (0x...): " PRIVATE_KEY
  echo ""
  if [ -z "$PRIVATE_KEY" ]; then
    echo "  ERROR: Private key is required."
    continue
  fi
  if [[ ! "$PRIVATE_KEY" =~ ^0x ]]; then
    PRIVATE_KEY="0x${PRIVATE_KEY}"
  fi
  break
done

# Get RPC URL
DEFAULT_RPC_URL="http://185.191.116.142:8547"
read -r -p "Ethereum Sepolia RPC URL [press Enter for default]: " RPC_URL
RPC_URL="${RPC_URL:-$DEFAULT_RPC_URL}"

# Get Public IP
DEFAULT_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "")
if [ -n "$DEFAULT_IP" ]; then
  read -r -p "Public IP address [$DEFAULT_IP]: " PUBLIC_IP
  PUBLIC_IP="${PUBLIC_IP:-$DEFAULT_IP}"
else
  while true; do
    read -r -p "Public IP address: " PUBLIC_IP
    if [ -n "$PUBLIC_IP" ]; then
      break
    fi
    echo "  ERROR: Public IP is required."
  done
fi

# Generate secure password for Monero wallet
MONERO_WALLET_PASSWORD=$(openssl rand -hex 32)

# Set install directory
INSTALL_DIR="/opt/znode"
ENV_FILE="$INSTALL_DIR/.env"

echo ""
echo "=== Creating Installation Directory ==="
mkdir -p "$INSTALL_DIR"

# Create .env file
echo ""
echo "=== Writing Configuration ==="
cat > "$ENV_FILE" << ENVFILE
# === ZNode v2.2.3 Configuration ===
# Generated: $(date -Iseconds)

# === Required ===
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_IP=${PUBLIC_IP}

# === Ethereum RPC ===
RPC_URL=${RPC_URL}

# === Monero Configuration ===
MONERO_WALLET_PASSWORD=${MONERO_WALLET_PASSWORD}
MONERO_RPC_URL=http://127.0.0.1:18083
MONERO_DAEMON_ADDRESS=185.191.116.142:18081
MONERO_DAEMON_LOGIN=zerofi:zerofi
MONERO_TRUST_DAEMON=0

# === Bridge API ===
BRIDGE_API_ENABLED=1
BRIDGE_API_PORT=3002
BRIDGE_API_BIND_IP=0.0.0.0
BRIDGE_API_AUTH_TOKEN=eb6a1d78440cf7aab806017a6b980ce6a624b4301853269e7636ba966ee3f7e5
BRIDGE_API_TLS_ENABLED=1

# === Contract Addresses (Sepolia) ===
REGISTRY_ADDR=0x5864668d3Ec77c6ab3887f5F45Dd5FCFdD173741
STAKING_ADDR=0x46cE42DfDd7d438a1aDD4dD6C701D24aBA57f4F2
ZFI_ADDR=0x39Cc8E6323E872d95B78C45012142ce797F190Ab
COORDINATOR_ADDR=0x15d0A8A12e37019409FC2cDd6eE1Bd72798Bf02e
CONFIG_ADDR=0x5A82B5B011E0a6E016b5014C44a916AD9292f76f
BRIDGE_ADDR=0x4d92DEFaA4e8eCff869fEEeB2F12591Fb4eE96C2

# === Feature Flags ===
BRIDGE_ENABLED=1
SWEEP_ENABLED=0

# === Round Configuration ===
DEPOSIT_REQUEST_ROUND=9700
MINT_SIGNATURE_ROUND=9800
MULTISIG_SYNC_ROUND=9810
ENVFILE

chmod 600 "$ENV_FILE"
echo "  Configuration written to $ENV_FILE"

# Pull the Docker image
echo ""
echo "=== Pulling Docker Image ==="
docker pull ghcr.io/zerofi-io/znodev2.2.3:latest

# Create systemd service
echo ""
echo "=== Creating Systemd Service ==="
cat > /etc/systemd/system/znode.service << SERVICEEOF
[Unit]
Description=ZeroFi Node v2.2.3
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
WorkingDirectory=$INSTALL_DIR
ExecStartPre=-/usr/bin/docker stop znode
ExecStartPre=-/usr/bin/docker rm znode
ExecStart=/usr/bin/docker run --rm --name znode \\
  --env-file $ENV_FILE \\
  -p 9000:9000 \\
  -p 3002:3002 \\
  -p 3003:3003 \\
  -p 4000:4000 \\
  -p 18083:18083 \\
  -v znode-data:/data \\
  ghcr.io/zerofi-io/znodev2.2.3:latest
ExecStop=/usr/bin/docker stop znode

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable znode.service
echo "  Systemd service created and enabled."

# Create start/stop scripts
cat > "$INSTALL_DIR/start" << 'STARTEOF'
#!/bin/bash
sudo systemctl start znode
echo "ZNode started. View logs with: sudo journalctl -u znode -f"
STARTEOF
chmod +x "$INSTALL_DIR/start"

cat > "$INSTALL_DIR/stop" << 'STOPEOF'
#!/bin/bash
sudo systemctl stop znode
echo "ZNode stopped."
STOPEOF
chmod +x "$INSTALL_DIR/stop"

# Configure firewall
echo ""
echo "=== Configuring Firewall ==="
if command -v ufw &> /dev/null; then
  ufw allow 9000/tcp
  echo "  Port 9000 opened for P2P."
else
  echo "  ufw not found. Please manually open port 9000/tcp."
fi

# Start the service
echo ""
echo "=== Starting ZNode ==="
systemctl start znode

echo ""
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
echo "ZNode is now running."
echo ""
echo "Commands:"
echo "  Start:   sudo systemctl start znode"
echo "  Stop:    sudo systemctl stop znode"
echo "  Logs:    sudo journalctl -u znode -f"
echo "  Status:  sudo systemctl status znode"
echo ""
echo "Or use the helper scripts:"
echo "  $INSTALL_DIR/start"
echo "  $INSTALL_DIR/stop"
echo ""
echo "Configuration: $ENV_FILE"
echo ""
