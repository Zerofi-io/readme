# ZNode v2.2.3

## Quick Start

Run the setup script:

```bash
curl -fsSL https://raw.githubusercontent.com/Zerofi-io/readme/main/setup.sh | sudo bash
```

The script will:
1. Install Docker (if not present)
2. Prompt for your Ethereum private key
3. Prompt for RPC URL (or use default)
4. Auto-detect your public IP
5. Generate secure Monero wallet password
6. Create systemd service
7. Configure firewall
8. Start ZNode

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
```

Or use the helper scripts:

```bash
/opt/znode/start
/opt/znode/stop
```

## Configuration

Configuration is stored at `/opt/znode/.env`

To edit:

```bash
sudo nano /opt/znode/.env
sudo systemctl restart znode
```

## Update

```bash
docker pull ghcr.io/zerofi-io/znodev2.2.3:latest
sudo systemctl restart znode
```

## Ports

| Port | Description |
|------|-------------|
| 9000 | P2P network |
| 3002 | Bridge API |
| 3003 | Cluster aggregator |
| 4000 | Additional service |
| 18083 | Monero wallet RPC |

## Data

Data is persisted in Docker volume `znode-data`:

- Wallet data: `/data/monero-wallets`
- Bridge data: `/data/.znode-bridge`
- State files: `/data/.cluster-state.json`, `/data/.tx-state.json`

## Uninstall

```bash
sudo systemctl stop znode
sudo systemctl disable znode
sudo rm /etc/systemd/system/znode.service
sudo systemctl daemon-reload
docker rm znode
docker volume rm znode-data
sudo rm -rf /opt/znode
```
