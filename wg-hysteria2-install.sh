#!/bin/bash

set -e

# === CONFIG ===
WG_PORT=51820
HY_PORT=8443
WG_SUBNET="10.10.0.0/24"
WG_INTERFACE="wg0"
WG_SECRET=$(openssl rand -hex 16)
DOMAIN_OR_IP=$(curl -s https://ipinfo.io/ip)
TLS_DIR="/etc/hysteria"

# === Install WireGuard ===
apt update
apt install -y wireguard curl

# === Generate Keys ===
wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key

SERVER_PRIV=$(cat server_private.key)
SERVER_PUB=$(cat server_public.key)
CLIENT_PRIV=$(cat client_private.key)
CLIENT_PUB=$(cat client_public.key)

# === WireGuard Config ===
cat > /etc/wireguard/$WG_INTERFACE.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = 10.10.0.1/24
ListenPort = $WG_PORT
SaveConfig = true

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.10.0.2/32
EOF

# === Enable WireGuard ===
systemctl enable wg-quick@$WG_INTERFACE
systemctl start wg-quick@$WG_INTERFACE

# === Install Hysteria 2 ===
curl -L https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64 -o /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# === Generate TLS Cert ===
mkdir -p $TLS_DIR
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout $TLS_DIR/key.pem -out $TLS_DIR/cert.pem \
  -days 3650 -subj "/CN=$DOMAIN_OR_IP"

# === Hysteria 2 Config ===
cat > $TLS_DIR/config.yaml <<EOF
listen: :$HY_PORT
tls:
  cert: $TLS_DIR/cert.pem
  key: $TLS_DIR/key.pem
  alpn:
    - h3
fallback:
  type: wireguard
  server: 127.0.0.1:$WG_PORT
  secret: $WG_SECRET
EOF

# === Create systemd service ===
cat > /etc/systemd/system/hysteria2.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c $TLS_DIR/config.yaml
Restart=on-failure
User=nobody
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# === Start Hysteria ===
systemctl daemon-reexec
systemctl enable hysteria2
systemctl restart hysteria2

# === OUTPUT CLIENT CONFIG ===
echo -e "\n✅ INSTALL COMPLETE\n"

echo "🔐 WireGuard Client Config:"
echo "-----------------------------"
cat <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.10.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = 127.0.0.1:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo -e "\n🌐 Hysteria 2 Client YAML:"
echo "-----------------------------"
cat <<EOF
server: $DOMAIN_OR_IP:$HY_PORT
auth: $WG_SECRET
tls:
  insecure: true
  alpn:
    - h3
transport:
  type: wireguard
  local: 127.0.0.1:$WG_PORT
EOF

echo -e "\n✅ Use these configs with WireGuard and Hysteria 2 on Windows/Linux client."
