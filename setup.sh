#!/usr/bin/env bash

# Make apt fully noninteractive
export DEBIAN_FRONTEND=noninteractive

echo "============================================"
echo "  ZNode v2.2.3 Setup"
echo "============================================"
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo ./setup.sh)"
  exit 1
fi

wait_for_apt() {
  # Try to recover if a previous install left dpkg half-configured
  dpkg --configure -a >/dev/null 2>&1 || true

  # Wait politely for background package jobs to finish
  # (apt/apt-get/dpkg/unattended-upgrade)
  local waited=0
  local max_wait=600  # 10 minutes upper bound
  while pgrep -x apt >/dev/null || \
        pgrep -x apt-get >/dev/null || \
        pgrep -x dpkg >/dev/null || \
        pgrep -x unattended-upgrade >/dev/null; do
    sleep 3
    waited=$((waited+3))
    [ $waited -ge $max_wait ] && break
  done
}

apt_retry() {
  # Usage: apt_retry update
  #        apt_retry install pkg1 pkg2 ...
  #        apt_retry remove pkg
  local delay=3
  local tries=15
  local n=0
  while :; do
    wait_for_apt
    # -y assumes yes, Use-Pty=0 avoids TTY issues in pipelines, Acquire::Retries retries downloads
    if apt-get -y -o Dpkg::Use-Pty=0 -o Acquire::Retries=3 "$@"; then
      return 0
    fi
    n=$((n+1))
    if [ $n -ge $tries ]; then
      echo "ERROR: apt-get $* failed after $tries attempts" >&2
      return 1
    fi
    sleep "$delay"
    [ $delay -lt 30 ] && delay=$((delay*2))  # exponential backoff up to 30s
  done
}

# Remove podman-docker if present (it masquerades as docker)
if dpkg -l podman-docker &>/dev/null; then
  echo "Removing podman-docker (conflicts with Docker)..."
  apt_retry remove podman-docker
fi

# Setup Docker repository
setup_docker_repo() {
  echo "Setting up Docker repository..."
  apt_retry update
  apt_retry install ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt_retry update
}

# Check for real Docker (not podman wrapper)
if ! command -v docker &>/dev/null || file "$(which docker)" | grep -q "shell script"; then
  echo "Docker not found or is podman wrapper. Installing Docker..."
  setup_docker_repo
  apt_retry install docker-ce docker-ce-cli containerd.io docker-compose-plugin || {
    # Fallback to docker.io if docker-ce fails
    echo "docker-ce install failed, trying docker.io..."
    apt_retry install docker.io
  }
  systemctl enable docker
  systemctl start docker
  echo "Docker installed successfully."
  echo ""
fi

# Ensure Docker Compose is available
if ! docker compose version &>/dev/null; then
  echo "Docker Compose not found. Installing..."
  apt_retry update
  apt_retry install docker-compose-plugin || {
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


# Get Public IP (IPv4 or IPv6) (required)
is_valid_ipv4() {
  local ip="${1:-}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    ((o >= 0 && o <= 255)) || return 1
  done
  return 0
}

is_valid_ipv6() {
  local ip="${1:-}"
  python3 -c "import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])" "$ip" >/dev/null 2>&1
}

while true; do
  echo -n "Public IP address (IPv4 or IPv6): "
  read -r PUBLIC_IP </dev/tty
  if [ -z "$PUBLIC_IP" ]; then
    echo "  ERROR: Public IP is required."
    continue
  fi
  if is_valid_ipv4 "$PUBLIC_IP" || is_valid_ipv6 "$PUBLIC_IP"; then
    break
  fi
  echo "  ERROR: Please enter a valid public IPv4 or IPv6 address."
done

BRIDGE_API_BIND_IP="0.0.0.0"
if is_valid_ipv6 "$PUBLIC_IP"; then
  BRIDGE_API_BIND_IP="::"
fi

# Monero daemon (local only)
echo ""
echo "=== Monero Daemon Configuration ==="
echo ""
echo "Local monerod is mandatory. Using Docker service: monerod:18081"
USE_LOCAL_MONEROD="1"
MONERO_DAEMON_ADDRESS="monerod:18081"
MONERO_TRUST_DAEMON="1"

# Generate secure password for Monero wallet
MONERO_WALLET_PASSWORD=$(openssl rand -hex 32)

# Shared network-wide auth token (deterministic - all nodes produce the same value)
BRIDGE_API_AUTH_TOKEN=$(printf "zerofi-bridge-network-auth-v1" | sha256sum | cut -d" " -f1)

# Set install directory
INSTALL_DIR="/opt/znode"
# Skip if using external daemon
if grep -qE "^USE_LOCAL_MONEROD=0" "$INSTALL_DIR/.env" 2>/dev/null; then exit 0; fi

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
MONERO_TRUST_DAEMON=${MONERO_TRUST_DAEMON}
MONERO_DAEMON_PROBE_TIMEOUT_MS=15000
USE_LOCAL_MONEROD=${USE_LOCAL_MONEROD}

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
BRIDGE_API_BIND_IP=${BRIDGE_API_BIND_IP}
BRIDGE_API_AUTH_TOKEN=${BRIDGE_API_AUTH_TOKEN}
BRIDGE_API_TLS_ENABLED=0

# === Cluster Aggregator ===
CLUSTER_AGG_PORT=4000
CLUSTER_AGG_NODE_AUTH_TOKEN=${BRIDGE_API_AUTH_TOKEN}

# === Contract Addresses (Sepolia) ===
REGISTRY_ADDR=0x474D44dAd49B0010Aa6e0D9Fb65b83E76c3fFb01
STAKING_ADDR=0x2E9A81873003036D8919aB000CBf8A274FC92Dea
ZFI_ADDR=0x5f089fe95A58a3CC352837065BAA5198d5d784C3
COORDINATOR_ADDR=0x5A137532640Fae1A3aFf0c5Af487A04Efbd1367b
CONFIG_ADDR=0x180Fb286153C312e55AB7FBFD2B1273284A599f9
BRIDGE_ADDR=0x681DB287420cb64DC2b61d1A5c5274f94B80A032

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

# Create systemd service with conditional profile
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
ExecStartPre=/bin/bash -c 'if grep -qE "^USE_LOCAL_MONEROD=0" $INSTALL_DIR/.env 2>/dev/null; then echo "" > $INSTALL_DIR/.compose-profile; else echo "COMPOSE_PROFILES=local-daemon" > $INSTALL_DIR/.compose-profile; fi'
EnvironmentFile=-$INSTALL_DIR/.compose-profile
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable znode.service
echo "  Systemd service created and enabled."


# Install Monerod sync watchdog (restart if stuck)
echo ""
echo "=== Installing Monerod Watchdog ==="
cat > "$INSTALL_DIR/monerod-watchdog.sh" << 'WATCHDOGEOF'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/znode"
# Skip if using external daemon
if grep -qE "^USE_LOCAL_MONEROD=0" "$INSTALL_DIR/.env" 2>/dev/null; then exit 0; fi
STATE_FILE="$INSTALL_DIR/.monerod-watchdog.state"
THRESHOLD_SEC=600

cd "$INSTALL_DIR" || exit 0
now="$(date +%s)"

LAST_HEIGHT=0
LAST_CHANGE_TS=0
LAST_RESTART_TS=0
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE" || true
fi

LAST_HEIGHT="${LAST_HEIGHT:-0}"
LAST_CHANGE_TS="${LAST_CHANGE_TS:-0}"
LAST_RESTART_TS="${LAST_RESTART_TS:-0}"

cid="$(docker compose ps -q monerod 2>/dev/null || true)"
if [ -z "$cid" ]; then
  exit 0
fi

info="$(docker compose exec -T monerod curl -s --max-time 10 http://127.0.0.1:18081/get_info 2>/dev/null || true)"
height="$(printf '%s' "$info" | grep -oE '"height":[0-9]+' | head -n1 | cut -d: -f2 || true)"
target="$(printf '%s' "$info" | grep -oE '"target_height":[0-9]+' | head -n1 | cut -d: -f2 || true)"

case "$height" in ''|*[!0-9]*) height=0 ;; esac
case "$target" in ''|*[!0-9]*) target=0 ;; esac

# If target unknown, just track progress and avoid restarts.
if [ "$target" -le 0 ]; then
  if [ "$height" -ne "$LAST_HEIGHT" ]; then
    LAST_HEIGHT="$height"
    LAST_CHANGE_TS="$now"
  elif [ "$LAST_CHANGE_TS" -le 0 ]; then
    LAST_CHANGE_TS="$now"
  fi
  printf 'LAST_HEIGHT=%s
LAST_CHANGE_TS=%s
LAST_RESTART_TS=%s
' "$LAST_HEIGHT" "$LAST_CHANGE_TS" "$LAST_RESTART_TS" > "$STATE_FILE"
  exit 0
fi

# Synced
if [ "$height" -ge "$target" ]; then
  LAST_HEIGHT="$height"
  LAST_CHANGE_TS="$now"
  printf 'LAST_HEIGHT=%s
LAST_CHANGE_TS=%s
LAST_RESTART_TS=%s
' "$LAST_HEIGHT" "$LAST_CHANGE_TS" "$LAST_RESTART_TS" > "$STATE_FILE"
  exit 0
fi

# Syncing: restart if height hasn't moved for 10 minutes.
if [ "$height" -ne "$LAST_HEIGHT" ]; then
  LAST_HEIGHT="$height"
  LAST_CHANGE_TS="$now"
else
  if [ "$LAST_CHANGE_TS" -le 0 ]; then
    LAST_CHANGE_TS="$now"
  fi
  if [ $((now - LAST_CHANGE_TS)) -ge $THRESHOLD_SEC ] && [ $((now - LAST_RESTART_TS)) -ge $THRESHOLD_SEC ]; then
    docker compose restart monerod
    LAST_RESTART_TS="$now"
    LAST_CHANGE_TS="$now"
  fi
fi

printf 'LAST_HEIGHT=%s
LAST_CHANGE_TS=%s
LAST_RESTART_TS=%s
' "$LAST_HEIGHT" "$LAST_CHANGE_TS" "$LAST_RESTART_TS" > "$STATE_FILE"
WATCHDOGEOF
chmod +x "$INSTALL_DIR/monerod-watchdog.sh"

cat > /etc/systemd/system/monerod-watchdog.service << SERVICEEOF
[Unit]
Description=Monerod sync watchdog (restart if stuck)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/monerod-watchdog.sh
SERVICEEOF

cat > /etc/systemd/system/monerod-watchdog.timer << TIMEREOF
[Unit]
Description=Run monerod sync watchdog every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload
systemctl enable --now monerod-watchdog.timer

echo "  Monerod watchdog enabled (restarts monerod if height stalls for 10 minutes)."

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
# Human-readable logs focused on znode v2.2.3 only
cd /opt/znode || exit 1

# Follow only the znode service, no docker prefixes, and drop common mempool/RPC + p2p discovery noise
exec docker compose logs -f --no-log-prefix znode 2>&1 \
  | grep --line-buffered -vE "(Found new pool tx|mempool|pending tx|Calling RPC method|HTTP \[|\[p2p-daemon\].*\[Discovery\] Bootstrap peer|\[p2p-daemon\].*\[Discovery\] Failed to connect|\[p2p-daemon\].*\[Discovery\] Scheduled redial.*failed|\[p2p-daemon\].*Failed to connect to bootstrap peer|^\[p2p-daemon\][[:space:]]+\* \[/ip|\[p2p-daemon\].*(dial backoff|dial to self attempted))"
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
  echo "ZNode is now running with 4 services:"
  echo "  - monerod (Local Monero daemon - syncing blockchain)"
  echo "  - monero-wallet-rpc (Monero wallet management)"
  echo "  - znode (Main node service)"
  echo "  - cluster-aggregator (Cluster coordination)"
  echo ""
  echo "NOTE: The local Monero daemon needs to sync the blockchain."
  echo "      This may take several hours. Check sync status with:"
  echo "      docker compose logs -f monerod"
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
