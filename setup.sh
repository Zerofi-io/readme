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

# Remove podman-docker if present (it masquerades as docker)
if dpkg -l podman-docker &>/dev/null; then
  echo "Removing podman-docker (conflicts with Docker)..."
  apt-get remove -y podman-docker
fi

# Setup Docker repository
setup_docker_repo() {
  echo "Setting up Docker repository..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
}

# Check for real Docker (not podman wrapper)
if ! command -v docker &>/dev/null || file "$(which docker)" | grep -q "shell script"; then
  echo "Docker not found or is podman wrapper. Installing Docker..."
  setup_docker_repo
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || {
    # Fallback to docker.io if docker-ce fails
    echo "docker-ce install failed, trying docker.io..."
    apt-get install -y docker.io
  }
  systemctl enable docker
  systemctl start docker
  echo "Docker installed successfully."
  echo ""
fi

# Ensure Docker Compose is available
if ! docker compose version &>/dev/null; then
  echo "Docker Compose not found. Installing..."
  apt-get update
  apt-get install -y docker-compose-plugin || {
    echo "Installing docker-compose standalone..."
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
  }
  echo "Docker Compose installed successfully."
  echo ""
fi

echo "=== Required Configuration ==="
echo ""

# Get Ethereum private key (read from /dev/tty for pipe compatibility)
while true; do
  echo -n "Ethereum private key (0x...): "
  read -r -s PRIVATE_KEY </dev/tty
  echo ""
  # Sanitize: remove any non-hex characters except 'x'
  PRIVATE_KEY=$(echo "$PRIVATE_KEY" | tr -cd '0-9a-fA-Fx')
  if [ -z "$PRIVATE_KEY" ]; then
    echo "  ERROR: Private key is required."
    continue
  fi
  if [[ ! "$PRIVATE_KEY" =~ ^0x ]]; then
    PRIVATE_KEY="0x${PRIVATE_KEY}"
  fi
  # Validate length (should be 66 chars: 0x + 64 hex chars)
  if [ ${#PRIVATE_KEY} -ne 66 ]; then
    echo "  ERROR: Private key must be 64 hex characters (with 0x prefix)."
    continue
  fi
  break
done

# Get RPC URL
DEFAULT_RPC_URL="http://185.191.116.142:8547"
echo -n "Ethereum Sepolia RPC URL [$DEFAULT_RPC_URL]: "
read -r RPC_URL </dev/tty
RPC_URL="${RPC_URL:-$DEFAULT_RPC_URL}"

# Get Public IP
DEFAULT_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "")
if [ -n "$DEFAULT_IP" ]; then
  echo -n "Public IP address [$DEFAULT_IP]: "
  read -r PUBLIC_IP </dev/tty
  PUBLIC_IP="${PUBLIC_IP:-$DEFAULT_IP}"
else
  while true; do
    echo -n "Public IP address: "
    read -r PUBLIC_IP </dev/tty
    if [ -n "$PUBLIC_IP" ]; then
      break
    fi
    echo "  ERROR: Public IP is required."
  done
fi

echo ""
echo "=== Monero Daemon Configuration ==="
echo ""

# Get Monero daemon address
DEFAULT_MONERO_DAEMON="185.191.116.142:18081"
echo -n "Monero daemon address [$DEFAULT_MONERO_DAEMON]: "
read -r MONERO_DAEMON_ADDRESS </dev/tty
MONERO_DAEMON_ADDRESS="${MONERO_DAEMON_ADDRESS:-$DEFAULT_MONERO_DAEMON}"

# Get Monero daemon login
DEFAULT_MONERO_LOGIN="zerofi:zerofi"
echo -n "Monero daemon login (user:pass) [$DEFAULT_MONERO_LOGIN]: "
read -r MONERO_DAEMON_LOGIN </dev/tty
MONERO_DAEMON_LOGIN="${MONERO_DAEMON_LOGIN:-$DEFAULT_MONERO_LOGIN}"

# Generate secure password for Monero wallet
MONERO_WALLET_PASSWORD=$(openssl rand -hex 32)

# Generate auth token
BRIDGE_API_AUTH_TOKEN=$(openssl rand -hex 32)

# Set install directory
INSTALL_DIR="/opt/znode"

echo ""
echo "=== Creating Installation Directory ==="
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Create .env file
echo ""
echo "=== Writing Configuration ==="
cat > "$INSTALL_DIR/.env" << ENVFILE
# === ZNode v2.2.3 Configuration ===
# Generated: $(date -Iseconds)

# === Required ===
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_IP=${PUBLIC_IP}

# === Ethereum RPC ===
RPC_URL=${RPC_URL}
RPC_API_KEY=0c352d92ed1aa5d82b487c0908876f7ae8b0ed707aa0640aef767e77c0494f62
CHAIN_ID=11155111
CHAIN_NAME=sepolia

# === Monero Configuration ===
MONERO_WALLET_PASSWORD=${MONERO_WALLET_PASSWORD}
MONERO_DAEMON_ADDRESS=${MONERO_DAEMON_ADDRESS}
MONERO_DAEMON_LOGIN=${MONERO_DAEMON_LOGIN}
MONERO_TRUST_DAEMON=0

# === P2P Configuration ===
P2P_IMPL=libp2p
P2P_BOOTSTRAP_FROM_CHAIN=1
ENABLE_HEARTBEAT_ORACLE=1
ENABLE_MULTI_CLUSTER_FORMATION=1
ENABLE_HEARTBEAT_FILTERED_SELECTION=1
ENFORCE_SELECTED_MEMBERS_P2P_VISIBILITY=1
COOLDOWN_TO_NEXT_EPOCH_WINDOW=1
HEARTBEAT_ONLINE_TTL_MS=300000
HEARTBEAT_INTERVAL=30

# === Bridge Configuration ===
BRIDGE_ENABLED=1
SWEEP_ENABLED=0
BRIDGE_API_ENABLED=1
BRIDGE_API_PORT=3002
BRIDGE_API_BIND_IP=0.0.0.0
BRIDGE_API_AUTH_TOKEN=${BRIDGE_API_AUTH_TOKEN}
BRIDGE_API_TLS_ENABLED=0

# === Cluster Aggregator ===
CLUSTER_AGG_PORT=4000
CLUSTER_AGG_NODE_AUTH_TOKEN=${BRIDGE_API_AUTH_TOKEN}

# === Contract Addresses (Sepolia) ===
REGISTRY_ADDR=0x6884ed007286999021E17B4a31C960fC53d0dB93
STAKING_ADDR=0x46cE42DfDd7d438a1aDD4dD6C701D24aBA57f4F2
ZFI_ADDR=0x39Cc8E6323E872d95B78C45012142ce797F190Ab
COORDINATOR_ADDR=0x15d0A8A12e37019409FC2cDd6eE1Bd72798Bf02e
CONFIG_ADDR=0x5A82B5B011E0a6E016b5014C44a916AD9292f76f
BRIDGE_ADDR=0x4d92DEFaA4e8eCff869fEEeB2F12591Fb4eE96C2

# === Round Configuration ===
DEPOSIT_REQUEST_ROUND=9700
MINT_SIGNATURE_ROUND=9800
MULTISIG_SYNC_ROUND=9810

# === Timing Configuration ===
STALE_ROUND_MIN_AGE_MS=600000
STICKY_QUEUE=0
FORCE_SELECT=0
TEST_MODE=0
DRY_RUN=0
ENVFILE

chmod 600 "$INSTALL_DIR/.env"
echo "  Configuration written to $INSTALL_DIR/.env"

# Download docker-compose.yml
echo ""
echo "=== Downloading Docker Compose File ==="
curl -fsSL "https://raw.githubusercontent.com/Zerofi-io/readme/main/docker-compose.yml?$(date +%s)" -o "$INSTALL_DIR/docker-compose.yml"
echo "  Downloaded docker-compose.yml"

# Pull images
echo ""
echo "=== Pulling Docker Images ==="
docker compose pull

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
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable znode.service
echo "  Systemd service created and enabled."

# Create helper scripts
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

cat > "$INSTALL_DIR/logs" << 'LOGSEOF'
#!/bin/bash
sudo journalctl -u znode -f
LOGSEOF
chmod +x "$INSTALL_DIR/logs"

# Open firewall port if ufw is available
if command -v ufw &>/dev/null; then
  echo ""
  echo "=== Configuring Firewall ==="
  ufw allow 9000/tcp comment "ZNode P2P"
  ufw allow 4000/tcp comment "ZNode Cluster Aggregator"
  echo "  Opened ports 9000/tcp and 4000/tcp"
else
  echo ""
  echo "NOTE: ufw not found. Please manually open ports 9000/tcp and 4000/tcp."
fi

# Start the service
echo ""
echo "=== Starting ZNode ==="
systemctl start znode

# Wait for startup
echo "  Waiting for services to start..."
sleep 15

# Check status
if systemctl is-active --quiet znode; then
  echo ""
  echo "============================================"
  echo "  Setup Complete!"
  echo "============================================"
  echo ""
  echo "ZNode is now running with 3 services:"
  echo "  - monero-wallet-rpc (Monero wallet management)"
  echo "  - znode (Main node service)"
  echo "  - cluster-aggregator (Cluster coordination)"
  echo ""
  echo "Commands:"
  echo "  Start:   $INSTALL_DIR/start"
  echo "  Stop:    $INSTALL_DIR/stop"
  echo "  Logs:    $INSTALL_DIR/logs"
  echo "  Status:  sudo systemctl status znode"
  echo ""
  echo "Configuration: $INSTALL_DIR/.env"
  echo ""
else
  echo ""
  echo "WARNING: ZNode may not have started correctly."
  echo "Check logs with: sudo journalctl -u znode -n 50"
fi
