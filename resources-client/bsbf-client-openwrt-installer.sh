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
apk add curl kmod-ifb kmod-nft-tproxy bsbf-bonding xray-core

if ! apk info -e bsbf-bonding >/dev/null 2>&1; then
	echo "Installation failed. Try building an image from https://fs.bondingshouldbefree.org/ instead."
	exit 1
fi

if ! apk info -e xray-core >/dev/null 2>&1 || [ ! -x /usr/bin/xray ]; then
	echo "Installation failed: xray-core is not installed correctly."
	exit 1
fi

# OpenWrt's Xray init script uses /etc/config/xray for the service switch.
# Create the UCI section if the package did not provide one, then force it on.
if ! uci -q get xray.enabled.enabled >/dev/null 2>&1; then
	uci -q set xray.enabled='xray'
fi
uci set xray.enabled.enabled='1'
uci commit xray

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

# Enable Xray at boot. Do not start it yet: bsbf-bonding --enable generates
# /etc/xray/config.json with the server credentials first.
/etc/init.d/xray enable

# Let bsbf-bonding apply its complete client-side configuration. This also
# generates the Xray config, configures MPTCP endpoints, enables the nft rules,
# and restarts the required services.
if ! bsbf-bonding --enable; then
	echo "BSBF activation failed."
	exit 1
fi

# Reload networking so the BSBF fwmark-1 -> table-1 policy route becomes live.
/etc/init.d/network reload

# Explicitly restart Xray after BSBF generated its final configuration.
# This guarantees that /etc/config/xray=enabled and the generated config are
# both active in the running system.
/etc/init.d/xray restart

# Validate the generated Xray configuration and listener.
if [ ! -s /etc/xray/config.json ]; then
	echo "Installation failed: /etc/xray/config.json was not generated."
	exit 1
fi

if ! /usr/bin/xray run -test -c /etc/xray/config.json >/dev/null 2>&1; then
	echo "Installation failed: generated Xray configuration is invalid."
	echo "Run: /usr/bin/xray run -test -c /etc/xray/config.json"
	exit 1
fi

if ! ss -lntup 2>/dev/null | grep -q '127.0.0.1:12345'; then
	echo "Installation failed: Xray is enabled but is not listening on 127.0.0.1:12345."
	echo "Run: /etc/init.d/xray status"
	echo "Run: logread -e xray"
	exit 1
fi

# Install an independent OpenWrt uninstaller.
curl -fsSL https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-bonding-openwrt-uninstall.sh \
	-o /usr/sbin/bsbf-bonding-openwrt-uninstall
chmod 755 /usr/sbin/bsbf-bonding-openwrt-uninstall

echo
echo "BSBF OpenWrt installation complete."
echo "Xray UCI: $(uci -q get xray.enabled.enabled)"
echo "Xray listener: 127.0.0.1:12345"
echo "MPTCP endpoints:"
ip mptcp endpoint show 2>/dev/null || true
echo "Uninstall with: bsbf-bonding-openwrt-uninstall"
