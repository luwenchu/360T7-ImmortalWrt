#!/bin/sh

set -e
umask 077

export EASYRSA_PKI="/etc/easy-rsa/pki"
export EASYRSA_VARS_FILE="/etc/easy-rsa/vars-server"
export EASYRSA_CLI="easyrsa --batch"

FFDHE_PARAMETERS="/etc/openvpn/ffdhe2048.pem"
OPENVPN_PKI="/etc/openvpn/pki"

if [ ! -s "${FFDHE_PARAMETERS}" ]; then
	echo "Missing pre-generated FFDHE parameters: ${FFDHE_PARAMETERS}" >&2
	exit 1
fi

# Private keys remain unique to each router. Only the standardized, non-secret
# FFDHE group is prepared during the firmware build to avoid a long first boot.
printf 'yes\nyes\n' | ${EASYRSA_CLI} init-pki
${EASYRSA_CLI} build-ca nopass
${EASYRSA_CLI} build-server-full server nopass
${EASYRSA_CLI} build-client-full client1 nopass

mkdir -p "${OPENVPN_PKI}"
cp /etc/easy-rsa/pki/ca.crt "${OPENVPN_PKI}/ca.crt"
cp "${FFDHE_PARAMETERS}" "${OPENVPN_PKI}/dh.pem"
cp /etc/easy-rsa/pki/issued/server.crt "${OPENVPN_PKI}/server.crt"
cp /etc/easy-rsa/pki/private/server.key "${OPENVPN_PKI}/server.key"
cp /etc/easy-rsa/pki/issued/client1.crt "${OPENVPN_PKI}/client1.crt"
cp /etc/easy-rsa/pki/private/client1.key "${OPENVPN_PKI}/client1.key"
chmod 0644 \
	"${OPENVPN_PKI}/ca.crt" \
	"${OPENVPN_PKI}/dh.pem" \
	"${OPENVPN_PKI}/server.crt" \
	"${OPENVPN_PKI}/client1.crt"
chmod 0600 \
	"${OPENVPN_PKI}/server.key" \
	"${OPENVPN_PKI}/client1.key"

if [ "$(uci -q get openvpn.myvpn.enabled)" = "1" ]; then
	/etc/init.d/openvpn restart
fi

echo "OpenVPN certificate renewal completed"
