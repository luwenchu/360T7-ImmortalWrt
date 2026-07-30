#!/bin/sh

set -e
umask 077

ddns="$(uci -q get openvpn.myvpn.ddns)"
port="$(uci -q get openvpn.myvpn.port)"
proto="$(uci -q get openvpn.myvpn.proto | sed 's/server/client/g')"

cat > /tmp/my.ovpn <<EOF
client
dev tun
proto ${proto}
remote ${ddns} ${port}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verb 3
EOF

{
	echo '<ca>'
	cat /etc/openvpn/pki/ca.crt
	echo '</ca>'
	echo '<cert>'
	cat /etc/openvpn/pki/client1.crt
	echo '</cert>'
	echo '<key>'
	cat /etc/openvpn/pki/client1.key
	echo '</key>'
} >> /tmp/my.ovpn

[ -f /etc/openvpn-addon.conf ] && cat /etc/openvpn-addon.conf >> /tmp/my.ovpn
