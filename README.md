# ZNode v2.2.3

## Minimum VPS Requirements

Per node (one VPS):
- **CPU:** 2 vCPU (x86_64)
- **RAM:** 8 GB
- **Storage:** 150 GB SSD (includes ~100GB for local Monero blockchain)
- **OS:** Ubuntu 22.04 (or Debian with systemd)
- **Network:** Stable public IPv4, 100 Mbps+ recommended

> **Note:** One node per VPS. Running multiple nodes on a single machine is not supported.
> 
> Each node runs its own local Monero daemon (pruned mode, ~100GB). Initial blockchain sync takes several hours.

## Quick Start

Run the setup script:

```bash
curl -fsSL https://raw.githubusercontent.com/Zerofi-io/readme/main/setup.sh | sudo bash
```

The script will:
1. Install Docker and Docker Compose (if not present)
2. Prompt for your Ethereum private key
3. Prompt for RPC URL (or use default)
4. Auto-detect your public IP
5. Generate secure Monero wallet password
6. Download docker-compose.yml
7. Create systemd service
8. Configure firewall
9. Start all services (including local Monero daemon)

> **First startup:** The local Monero daemon needs to sync the blockchain. This takes several hours. The znode will wait for the daemon to be ready before starting.

## Update

To update an existing installation:

```bash
curl -fsSL https://raw.githubusercontent.com/Zerofi-io/readme/main/update.sh | sudo bash
```

This preserves your configuration and only updates the Docker images.

## Services

ZNode runs 4 containers:
- **monerod** - Local Monero daemon (pruned blockchain)
- **monero-wallet-rpc** - Monero wallet management
- **znode** - Main node service
- **cluster-aggregator** - Cluster management

## Commands

```bash
# Start
sudo systemctl start znode

# Stop
sudo systemctl stop znode

# View logs
sudo journalctl -u znode -f

# Check status
sudo systemctl status znode

# View container logs
cd /opt/znode && docker compose logs -f

# Check monerod sync progress
cd /opt/znode && docker compose logs monerod | tail -n 50
```

Or use helper scripts:

```bash
/opt/znode/start
/opt/znode/stop
/opt/znode/logs
```

## Configuration

Configuration is stored at `/opt/znode/.env`

To edit:

```bash
sudo nano /opt/znode/.env
sudo systemctl restart znode
```

## Ports

| Port | Description |
|------|-------------|
| 9000 | P2P network |
| 3002 | Bridge API |
| 3003 | Health/metrics |
| 4000 | Cluster aggregator API |

## Data

Data is persisted in Docker volumes:
- `znode-data` - Wallets, state files, bridge data
- `znode-tmp` - Temporary files
- `monerod-data` - Monero blockchain (~100GB pruned)

## Uninstall

```bash
sudo systemctl stop znode
sudo systemctl disable znode
sudo rm /etc/systemd/system/znode.service
sudo systemctl daemon-reload
cd /opt/znode && docker compose down -v
sudo rm -rf /opt/znode
```

> **Note:** `docker compose down -v` removes all data including the Monero blockchain. To preserve the blockchain for reinstallation, omit the `-v` flag.
