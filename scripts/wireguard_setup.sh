# #!/bin/bash
# ansible-playbook scripts/wireguard.yml 
# sudo groupadd wg_conf
# sudo usermod -aG wg_conf `whoami`
# sudo chown root.wg_conf /etc/wireguard/wg0.conf
# sudo chmod 664 /etc/wireguard/wg0.conf


#!/bin/bash

# Install WireGuard
#sudo apt update
#sudo apt install -y wireguard qrencode

# Enable IPv4 forwarding
#echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf

# Enable IPv6 forwarding
#echo "net.ipv6.conf.all.forwarding = 1" | sudo tee -a /etc/sysctl.conf
#sudo sysctl -p

# Generate Client And Server Keys
sudo mkdir -p /etc/wireguard

# Generate Server Keys
wg genkey | sudo tee /etc/wireguard/server_private.key
sudo chmod 600 /etc/wireguard/server_private.key
sudo cat /etc/wireguard/server_private.key | wg pubkey | sudo tee /etc/wireguard/server_public.key

# Generate Client Keys
wg genkey | sudo tee /etc/wireguard/client_private.key
sudo cat /etc/wireguard/client_private.key | wg pubkey | sudo tee /etc/wireguard/client_public.key


# Create Server Configuration
SERVER_PRIVATE_KEY=$(sudo cat /etc/wireguard/server_private.key)
CLIENT_PUBLIC_KEY=$(sudo cat /etc/wireguard/client_public.key)

cat << EOF | sudo tee /etc/wireguard/wg0.conf
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = 10.45.5.1/24
DNS = 172.10.0.2
ListenPort = 51820
PostUp = iptables -t nat -I POSTROUTING -o ens5 -j MASQUERADE
PostUp = ip6tables -t nat -I POSTROUTING -o ens5 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ens5 -j MASQUERADE
PostDown = ip6tables -t nat -D POSTROUTING -o ens5 -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.45.5.2/32
EOF

# Start WireGuard
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0


# Create Client Configuration
SERVER_PUBLIC_KEY=$(sudo cat /etc/wireguard/server_public.key)
CLIENT_PRIVATE_KEY=$(sudo cat /etc/wireguard/client_private.key)

SERVER_IPV6=$(ip -6 addr show dev ens5 | grep -oP '(?<=inet6 )([0-9a-f:]+)' | head -1)

# Or use IPv4 if your client doesn't have Ipv6 network
# SERVER_IPV4=$(curl checkip.amazonaws.com)

cat << EOF | sudo tee /etc/wireguard/client.conf
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.45.5.2/32
DNS = 172.10.0.2

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
# Or use IPV4 address if your client doesn't support IPv6
Endpoint = 54.254.78.116:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

# Generate QR code
echo "Generating QR code..."
sudo cat /etc/wireguard/client.conf | qrencode -t ansiutf8

echo "Current WireGuard status:"
sudo wg show
