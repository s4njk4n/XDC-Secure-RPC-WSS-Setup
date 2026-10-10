# XDC-Secure-RPC-WSS-Setup

Hardened, one-script installer for an **XDC Network** (Mainnet or Apothem Testnet) full node with **secure, access-controlled RPC and WebSocket (WSS) endpoints**.

It deploys the official [XinFin-Node](https://github.com/XinFinOrg/XinFin-Node) Docker setup and immediately locks it down with:

- Nginx reverse proxy
- TLS (Let’s Encrypt for domains **or** self-signed for public IPs)
- IP allow-list (ACL) on `/rpc` and `/wss`
- Localhost-only binding of the node’s RPC/WS ports
- UFW firewall + basic hardening

**Status:** Work in progress — functional but still being refined.

---

## Features

- One-command deployment of a secure XDC node
- Path-based endpoints on the same host:
  - `https://<host>/rpc`
  - `wss://<host>/wss`
- **Domain mode**: Let’s Encrypt certificate (requires DNS A record)
- **IP-only mode**: Automatic public IP detection + long-lived self-signed certificate
- IP whitelist (Nginx `allow`/`deny`)
- Node RPC/WS bound only to `127.0.0.1` (never exposed publicly)
- UFW locked down (SSH + P2P + 80/443 only)
- Fail2ban, system updates, and Docker installed automatically
- Supports both **mainnet** and **testnet** (Apothem)

---

## Prerequisites

- Ubuntu 20.04 / 22.04 / 24.04 (Debian-based) VPS or dedicated server
- Root (or `sudo`) access
- Open ports: **22** (SSH), **80**, **443**, **30303** (P2P)
- For domain mode: DNS A record already pointing to the server

Recommended minimum resources (full node):
- 6+ CPU cores
- 32 GB RAM
- 1.5+ TB SSD (grows over time)

---

## Quick Start

1. Clone the repository:

```bash
git clone https://github.com/s4njk4n/XDC-Secure-RPC-WSS-Setup.git
cd XDC-Secure-RPC-WSS-Setup
```

2. Edit the configuration section at the top of the script:

```bash
nano install_xdc_rpc_wss.sh
```

Important variables:

| Variable          | Description                                      | Example                          |
|-------------------|--------------------------------------------------|----------------------------------|
| `NETWORK`         | `mainnet` or `testnet`                           | `mainnet`                        |
| `INSTANCE_NAME`   | Name shown on network stats                      | `MySecureNode`                   |
| `CONTACT_EMAIL`   | Contact email for the node                       | `you@example.com`                |
| `DOMAIN`          | Domain name (leave empty for IP-only mode)       | `node.example.com` or `""`       |
| `PUBLIC_IP`       | Optional: force a specific public IP             | `203.0.113.10` or `""`           |
| `CERT_EMAIL`      | Email for Let’s Encrypt (domain mode only)       | `you@example.com`                |
| `ALLOWED_IPS`     | Space-separated list of allowed client IPs       | `("1.2.3.4" "5.6.7.8")`          |
| `SSH_PORT`        | Your SSH port (default 22)                       | `22`                             |

3. Make the script executable and run it:

```bash
chmod +x install_xdc_rpc_wss.sh
sudo ./install_xdc_rpc_wss.sh
```

The script will:

- Update the system and install Docker, Nginx, Certbot, UFW, Fail2ban, etc.
- Clone and configure the official XinFin-Node
- Start the node (Docker Compose)
- Configure UFW
- Obtain a certificate (or generate a self-signed one)
- Write a locked-down Nginx configuration
- Print the final endpoints

---

## Endpoints

After a successful run you will see something like:

**Domain mode**
```
RPC:  https://node.example.com/rpc
WSS:  wss://node.example.com/wss
```

**IP-only mode** (self-signed certificate)
```
RPC:  https://203.0.113.10/rpc
WSS:  wss://203.0.113.10/wss
```

### Testing

```bash
# Domain mode
curl -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  https://node.example.com/rpc

# IP mode (ignore self-signed warning)
curl -k -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  https://203.0.113.10/rpc
```

Expected result for Mainnet: `"result":"50"`  
Expected result for Testnet: `"result":"51"`

---

## Security Model

- Node RPC (`8989`/`8545`) and WS (`8888`/`8546`) are bound **only to localhost**.
- Nginx terminates TLS and enforces the IP allow-list.
- Only the IPs listed in `ALLOWED_IPS` can reach `/rpc` or `/wss`.
- All other requests are denied (`deny all`).
- UFW blocks everything except SSH, P2P (30303), HTTP, and HTTPS.
- HTTP is automatically redirected to HTTPS.

### Adding more allowed IPs later

Edit the Nginx site config and reload:

```bash
sudo nano /etc/nginx/sites-available/xdc-node
# Add more "allow x.x.x.x;" lines inside the /rpc and /wss location blocks
sudo nginx -t && sudo systemctl reload nginx
```

---

## Useful Commands

```bash
# Node status
cd ~/XinFin-Node/mainnet   # or testnet
docker compose ps
docker compose logs -f

# Coinbase / validator address
cat xdcchain/coinbase.txt

# Check Nginx
sudo nginx -t
sudo systemctl status nginx
```

---

## Troubleshooting

| Problem                          | Solution                                                                 |
|----------------------------------|--------------------------------------------------------------------------|
| Certbot fails                    | Ensure DNS A record points to the server and ports 80/443 are open.    |
| “Could not detect public IP”     | Set `PUBLIC_IP` manually in the script and re-run.                      |
| Connection refused / 403         | Your client IP is not in `ALLOWED_IPS`.                                 |
| Self-signed certificate warning  | Use `curl -k` or import the cert into your client trust store.          |
| Node not syncing                 | Check logs: `docker compose logs -f`. Ensure port 30303 is open.        |

---

## License

MIT — see [LICENSE](LICENSE).

---

## Disclaimer

This script is provided as-is. Always review the script before running it on a production server. You are responsible for the security and maintenance of your node.

---

**Author:** [s4njk4n](https://github.com/s4njk4n)  
Related guides: [XDC Outpost](https://xdcoutpost.xyz)

Special thanks: @inv4fee2020 for ealier version scripts we've built on top of
