#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  ZNode Update"
echo "============================================"
echo ""

INSTALL_DIR="/opt/znode"

# === Contract Addresses (Sepolia) ===
REGISTRY_ADDR="0x474D44dAd49B0010Aa6e0D9Fb65b83E76c3fFb01"
STAKING_ADDR="0x2E9A81873003036D8919aB000CBf8A274FC92Dea"
ZFI_ADDR="0x5f089fe95A58a3CC352837065BAA5198d5d784C3"
COORDINATOR_ADDR="0x5A137532640Fae1A3aFf0c5Af487A04Efbd1367b"
CONFIG_ADDR="0x180Fb286153C312e55AB7FBFD2B1273284A599f9"
BRIDGE_ADDR="0x681DB287420cb64DC2b61d1A5c5274f94B80A032"

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

echo "Configuring Monero daemon..."
# Ensure USE_LOCAL_MONEROD exists (default to 1)
if ! grep -q '^USE_LOCAL_MONEROD=' "$INSTALL_DIR/.env" 2>/dev/null; then
  echo 'USE_LOCAL_MONEROD=1' >> "$INSTALL_DIR/.env"
fi
# Only enforce local daemon settings if USE_LOCAL_MONEROD != 0
if ! grep -qE '^USE_LOCAL_MONEROD=0' "$INSTALL_DIR/.env" 2>/dev/null; then
  if grep -q '^MONERO_DAEMON_ADDRESS=' "$INSTALL_DIR/.env" 2>/dev/null; then
    sed -i 's/^MONERO_DAEMON_ADDRESS=.*/MONERO_DAEMON_ADDRESS=monerod:18081/' "$INSTALL_DIR/.env"
  else
    echo 'MONERO_DAEMON_ADDRESS=monerod:18081' >> "$INSTALL_DIR/.env"
  fi
  if grep -q '^MONERO_TRUST_DAEMON=' "$INSTALL_DIR/.env" 2>/dev/null; then
    sed -i 's/^MONERO_TRUST_DAEMON=.*/MONERO_TRUST_DAEMON=1/' "$INSTALL_DIR/.env"
  else
    echo 'MONERO_TRUST_DAEMON=1' >> "$INSTALL_DIR/.env"
  fi
fi

echo "Updating contract addresses..."
sed -i \
  -e "s/^REGISTRY_ADDR=.*/REGISTRY_ADDR=$REGISTRY_ADDR/" \
  -e "s/^STAKING_ADDR=.*/STAKING_ADDR=$STAKING_ADDR/" \
  -e "s/^ZFI_ADDR=.*/ZFI_ADDR=$ZFI_ADDR/" \
  -e "s/^CONFIG_ADDR=.*/CONFIG_ADDR=$CONFIG_ADDR/" \
  -e "s/^BRIDGE_ADDR=.*/BRIDGE_ADDR=$BRIDGE_ADDR/" \
  "$INSTALL_DIR/.env"

# Add COORDINATOR_ADDR if missing
if grep -q '^COORDINATOR_ADDR=' "$INSTALL_DIR/.env" 2>/dev/null; then
  sed -i "s/^COORDINATOR_ADDR=.*/COORDINATOR_ADDR=$COORDINATOR_ADDR/" "$INSTALL_DIR/.env"
else
  echo "COORDINATOR_ADDR=$COORDINATOR_ADDR" >> "$INSTALL_DIR/.env"
fi

echo "Updating Monero daemon probe timeout..."
if grep -q 'MONERO_DAEMON_PROBE_TIMEOUT_MS' "$INSTALL_DIR/.env"; then
  sed -i 's/^MONERO_DAEMON_PROBE_TIMEOUT_MS=.*/MONERO_DAEMON_PROBE_TIMEOUT_MS=15000/' "$INSTALL_DIR/.env"
else
  echo 'MONERO_DAEMON_PROBE_TIMEOUT_MS=15000' >> "$INSTALL_DIR/.env"
fi

echo "Updating systemd service..."
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

echo "Installing Monerod Watchdog (restart if stuck)..."
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
  printf 'LAST_HEIGHT=%s\nLAST_CHANGE_TS=%s\nLAST_RESTART_TS=%s\n' "$LAST_HEIGHT" "$LAST_CHANGE_TS" "$LAST_RESTART_TS" > "$STATE_FILE"
  exit 0
fi

# Synced
if [ "$height" -ge "$target" ]; then
  LAST_HEIGHT="$height"
  LAST_CHANGE_TS="$now"
  printf 'LAST_HEIGHT=%s\nLAST_CHANGE_TS=%s\nLAST_RESTART_TS=%s\n' "$LAST_HEIGHT" "$LAST_CHANGE_TS" "$LAST_RESTART_TS" > "$STATE_FILE"
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

printf 'LAST_HEIGHT=%s\nLAST_CHANGE_TS=%s\nLAST_RESTART_TS=%s\n' "$LAST_HEIGHT" "$LAST_CHANGE_TS" "$LAST_RESTART_TS" > "$STATE_FILE"
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

echo "Pulling latest images..."
docker compose pull

echo "Starting ZNode..."
systemctl start znode

echo ""
echo "============================================"
echo "  Update Complete!"
echo "============================================"
echo ""
echo "Running with local Monero daemon (mandatory)."
echo ""
echo "View logs: sudo journalctl -u znode -f"
