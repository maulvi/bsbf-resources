#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Chester A. Unal <chester.a.unal@arinc9.com>

set -u

usage() {
	echo "Usage: $0 --server-ipv4 <ADDR> --server-port <PORT> --uuid <UUID>"
	exit 1
}

# Parse arguments.
while [ $# -gt 0 ]; do
	case "$1" in
	--server-ipv4)
		[ -z "${2:-}" ] && usage
		server_ipv4="$2"
		shift 2
		;;
	--server-port)
		[ -z "${2:-}" ] && usage
		server_port="$2"
		shift 2
		;;
	--uuid)
		[ -z "${2:-}" ] && usage
		uuid="$2"
		shift 2
		;;
	*)
		usage
		;;
	esac
done

{ [ -z "${server_ipv4:-}" ] || [ -z "${server_port:-}" ] || [ -z "${uuid:-}" ]; } && usage

[ "$(id -u)" -eq 0 ] || {
	echo "Run this installer as root."
	exit 1
}

echo "Configuring bsbf-bonding."
mkdir -p /etc/bsbf
cat <<EOF > /etc/bsbf/bsbf-bonding.conf
server_ipv4=$server_ipv4
server_port=$server_port
uuid=$uuid
EOF

echo "Installing BSBF and required packages."
apk add curl kmod-ifb kmod-nft-tproxy bsbf-bonding

if ! apk info -e bsbf-bonding >/dev/null 2>&1; then
	echo "Installation failed. Try building an image from https://fs.bondingshouldbefree.org/ instead."
	exit 1
fi

# bsbf-bonding depends on xray-core. Configure the OpenWrt Xray service
# used by BSBF's TPROXY path.
uci set xray.enabled.enabled='1'

# Preserve the user's existing LAN/WAN topology. Only create/update the
# BSBF-specific policy-routing entries required by the TPROXY mark.
uci set network.bsbf_tproxy_rule=rule
uci set network.bsbf_tproxy_rule.priority='100'
uci set network.bsbf_tproxy_rule.lookup='1'
uci set network.bsbf_tproxy_rule.mark='1'

uci set network.bsbf_tproxy_route=route
uci set network.bsbf_tproxy_route.interface='loopback'
uci set network.bsbf_tproxy_route.type='local'
uci set network.bsbf_tproxy_route.target='0.0.0.0/0'
uci set network.bsbf_tproxy_route.table='1'

uci commit network
uci commit xray

# Enable and start BSBF components.
/etc/init.d/xray enable
/etc/init.d/xray restart

# Install the BSBF nftables interception rules.
/etc/init.d/bsbf-bonding-nft enable
/etc/init.d/bsbf-bonding-nft restart

# Configure and start MPTCP endpoints.
/etc/init.d/bsbf-mptcp enable
/etc/init.d/bsbf-mptcp restart

# Let bsbf-bonding apply its client-side configuration.
bsbf-bonding --enable

# Ensure the network stack sees the new UCI policy-routing entries.
/etc/init.d/network reload

# Install an independent OpenWrt uninstaller.
curl -fsSL https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-bonding-openwrt-uninstall.sh \
	-o /usr/sbin/bsbf-bonding-openwrt-uninstall
chmod 755 /usr/sbin/bsbf-bonding-openwrt-uninstall

echo

echo "BSBF OpenWrt installation complete."
echo "Xray: $(ss -lntup 2>/dev/null | grep -c '127.0.0.1:12345') listener(s)"
echo "MPTCP endpoints:"
ip mptcp endpoint show 2>/dev/null || true
echo "Uninstall with: bsbf-bonding-openwrt-uninstall"
