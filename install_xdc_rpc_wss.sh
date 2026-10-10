#!/bin/bash
# Hardened XDC node installer with Nginx ACL + localhost-only RPC/WS
# Supports both domain (Let's Encrypt) and public-IP (self-signed) modes
# Path-based endpoints: /rpc and /wss on the same host

set -euo pipefail

# ========== CONFIGURE THESE ==========
NETWORK="mainnet"                          # mainnet or testnet
INSTANCE_NAME="s4njk4n_Secure_RPCWSS"          # Node name shown on network stats
CONTACT_EMAIL="your@email.com"            # Contact email
# Leave DOMAIN empty for public-IP + self-signed certificate mode.
# If set, DNS A record must already point to this server.
DOMAIN=""                                  # e.g. "node.yourdomain.com" or ""
# Optional: force a specific public IP (only used when DOMAIN is empty). Leave empty for auto-detect.
PUBLIC_IP=""
CERT_EMAIL="your@email.com"               # Let's Encrypt email (used only with DOMAIN)
ALLOWED_IPS=("1.2.3.4" "5.6.7.8")  # Whitelist IPs (space-separated). Add more as needed.
SSH_PORT="22"                             # Change if you use a non-standard SSH port
# =====================================

if [[ "$NETWORK" != "mainnet" && "$NETWORK" != "testnet" ]]; then
  echo "NETWORK must be mainnet or testnet"; exit 1
fi

NODE_DIR="$HOME/XinFin-Node"
CHAIN_DIR="$NODE_DIR/$NETWORK"

echo "=== Updating system and installing prerequisites ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release git jq nginx certbot python3-certbot-nginx ufw fail2ban openssl

echo "=== Installing Docker with Intel CPU workaround ==="
apt-get remove -y docker docker-engine docker.io containerd runc docker-compose || true
rm -f /usr/local/bin/docker-compose || true

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

apt-get remove -y docker-ce-rootless-extras || true
apt-mark hold docker-ce-rootless-extras
systemctl restart docker
usermod -aG docker "$SUDO_USER" || true

echo "=== Cloning XinFin-Node ==="
if [[ ! -d "$NODE_DIR" ]]; then
  git clone https://github.com/XinFinOrg/XinFin-Node.git "$NODE_DIR"
else
  cd "$NODE_DIR" && git pull || true
fi
cd "$CHAIN_DIR"

echo "=== Configuring .env ==="
cp -n env.example .env || true
sed -i "s/^INSTANCE_NAME=.*/INSTANCE_NAME=${INSTANCE_NAME}/" .env
sed -i "s/^CONTACT_DETAILS=.*/CONTACT_DETAILS=${CONTACT_EMAIL}/" .env
sed -i "s/^ENABLE_RPC=.*/ENABLE_RPC=true/" .env
sed -i "s/^ENABLE_WS=.*/ENABLE_WS=true/" .env
sed -i "s/^GC_MODE=.*/GC_MODE=full/" .env

RPC_PORT=$(grep '^RPC_PORT=' .env | cut -d= -f2 || echo 8989)
WS_PORT=$(grep '^WS_PORT=' .env | cut -d= -f2 || echo 8888)

echo "=== Modifying docker-compose.yml (bridge mode + localhost-only RPC/WS) ==="
cp -n docker-compose.yml docker-compose.yml.bak || true

IMAGE=$(grep -A1 'image:' docker-compose.yml.bak | head -1 | awk '{print $2}' || echo "xinfinorg/xdposchain:v2.7.0")

cat > docker-compose.yml << EOF
services:
  xinfinnetwork:
    container_name: xdcnetwork-${NETWORK}-node
    image: ${IMAGE}
    volumes:
      - "./xdcchain:/work/xdcchain"
      - "./genesis.json:/work/genesis.json"
      - "./start-node.sh:/work/start.sh"
      - "./bootnodes.list:/work/bootnodes.list"
      - "./.pwd:/work/.pwd"
      - "/etc/localtime:/etc/localtime:ro"
    pull_policy: always
    restart: "always"
    env_file:
      - .env
    ports:
      - "30303:30303"
      - "127.0.0.1:${RPC_PORT}:${RPC_PORT}"
      - "127.0.0.1:${WS_PORT}:${WS_PORT}"
EOF

if [[ "$NETWORK" == "testnet" ]]; then
  sed -i 's|start-node.sh|start-apothem.sh|' docker-compose.yml
  sed -i 's|./xdcchain:|./xdcchain-testnet:|' docker-compose.yml || true
fi

echo "=== Starting the node ==="
docker compose -f docker-compose.yml up -d
sleep 15
docker compose -f docker-compose.yml logs --tail 50 || true

echo "=== Configuring UFW ==="
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'SSH'
ufw allow 30303/tcp comment 'XDC P2P'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

echo "=== Configuring Fail2Ban (SSH jail) ==="
# Copy base config if jail.local does not exist yet
if [[ ! -f /etc/fail2ban/jail.local ]]; then
  cp -p /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi

# Drop-in override (preferred over editing the large jail.local).
# Uses the script’s SSH_PORT so bans apply to the correct port.
# Settings match the article: 3 attempts in 1 day → permanent ban.
cat > /etc/fail2ban/jail.d/sshd-hardened.local << EOF
[sshd]
enabled = true
filter = sshd
port = ${SSH_PORT}
banaction = iptables-multiport
findtime = 86400
# 86400 seconds = 1 day
bantime = -1
# -1 = ban forever
maxretry = 3
# 3 attempts in 1 day = ban
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

systemctl restart fail2ban
systemctl enable fail2ban

echo ""
echo "Fail2Ban SSH jail active. Status: fail2ban-client status sshd"
echo "Unban example: fail2ban-client set sshd unban <ip>"
echo ""

# ---------- Host / certificate logic ----------
if [[ -n "$DOMAIN" ]]; then
  HOST="$DOMAIN"
  CERT_FULLCHAIN="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  CERT_PRIVKEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  SSL_INCLUDE='include /etc/letsencrypt/options-ssl-nginx.conf; ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;'
  MODE="domain"

  echo "=== Temporary HTTP config for Certbot ==="
  cat > /etc/nginx/sites-available/xdc-node << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location / {
        return 200 'Certbot validation ready';
        add_header Content-Type text/plain;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/xdc-node /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx || systemctl start nginx

  echo "=== Obtaining Let's Encrypt certificate ==="
  certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${CERT_EMAIL}" --redirect || {
    echo "WARNING: Certbot failed. Ensure DNS points to this server and ports 80/443 are reachable. You may need to re-run certbot manually."
  }
else
  # IP-only mode
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP=$(curl -4 -s --max-time 10 ifconfig.me || curl -4 -s --max-time 10 icanhazip.com || curl -4 -s --max-time 10 ipinfo.io/ip || true)
  fi
  if [[ -z "$PUBLIC_IP" ]]; then
    echo "Could not detect public IP. Set PUBLIC_IP in the config section and re-run."; exit 1
  fi
  HOST="$PUBLIC_IP"
  mkdir -p /etc/nginx/ssl
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/xdc-selfsigned.key \
    -out /etc/nginx/ssl/xdc-selfsigned.crt \
    -subj "/CN=${PUBLIC_IP}" \
    -addext "subjectAltName=IP:${PUBLIC_IP}"
  CERT_FULLCHAIN="/etc/nginx/ssl/xdc-selfsigned.crt"
  CERT_PRIVKEY="/etc/nginx/ssl/xdc-selfsigned.key"
  SSL_INCLUDE='ssl_protocols TLSv1.2 TLSv1.3; ssl_prefer_server_ciphers off;'
  MODE="ip"
fi

# Build allow lines for ACL
ALLOW_LINES=""
for ip in "${ALLOWED_IPS[@]}"; do
  ALLOW_LINES+="        allow ${ip};"$'\n'
done

echo "=== Writing final Nginx configuration (path-based /rpc and /wss) ==="
cat > /etc/nginx/sites-available/xdc-node << EOF
# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name ${HOST};
    return 301 https://\$host\$request_uri;
}

# HTTPS with /rpc and /wss
server {
    listen 443 ssl http2;
    server_name ${HOST};

    ssl_certificate ${CERT_FULLCHAIN};
    ssl_certificate_key ${CERT_PRIVKEY};
    ${SSL_INCLUDE}

    add_header Strict-Transport-Security "max-age=31536000" always;

    location /rpc {
${ALLOW_LINES}        deny all;

        proxy_pass http://127.0.0.1:${RPC_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }

    location /wss {
${ALLOW_LINES}        deny all;

        proxy_pass http://127.0.0.1:${WS_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    location / {
        return 404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/xdc-node /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
echo ""
nginx -t && systemctl reload nginx
echo ""

echo "=== Done ==="
echo ""
echo "Node status: docker compose -f $CHAIN_DIR/docker-compose.yml ps"
echo "Coinbase: cat $CHAIN_DIR/xdcchain/coinbase.txt  (or xdcchain-testnet for testnet)"
echo ""

if [[ "$MODE" == "domain" ]]; then
  echo "RPC:  https://${HOST}/rpc"
  echo "WSS:  wss://${HOST}/wss"
  echo ""
  echo "Test: curl -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"net_version\",\"params\":[],\"id\":1}' https://${HOST}/rpc"
  echo ""
else
  echo "RPC:  https://${HOST}/rpc   (self-signed cert – use curl -k or accept the warning)"
  echo "WSS:  wss://${HOST}/wss"
  echo ""
  echo "Test: curl -k -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"net_version\",\"params\":[],\"id\":1}' https://${HOST}/rpc"
  echo ""
fi

echo "Only IPs listed in ALLOWED_IPS can reach the endpoints. Edit /etc/nginx/sites-available/xdc-node and reload nginx to add more."
echo "For domain mode, DNS must have been pointed correctly before this run for Let's Encrypt to succeed."
echo ""
