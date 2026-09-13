#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Chester A. Unal <chester.a.unal@arinc9.com>

set -u

BSBF_TABLE=1
BSBF_MARK=0x1
BSBF_MARK_MASK=0xff
BSBF_RULE_PRIORITY=100
BSBF_TPROXY_PORT=12345

usage() {
	echo "Usage: $0 --server-ipv4 <ADDR> --server-port <PORT> --uuid <UUID>"
	exit 1
}

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
uci set network.bsbf_tproxy_rule.priority="$BSBF_RULE_PRIORITY"
uci set network.bsbf_tproxy_rule.lookup="$BSBF_TABLE"
uci set network.bsbf_tproxy_rule.mark="$BSBF_MARK"
uci set network.bsbf_tproxy_rule.mask="$BSBF_MARK_MASK"

uci set network.bsbf_tproxy_route=route
uci set network.bsbf_tproxy_route.interface='loopback'
uci set network.bsbf_tproxy_route.type='local'
uci set network.bsbf_tproxy_route.target='0.0.0.0/0'
uci set network.bsbf_tproxy_route.table="$BSBF_TABLE"

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

# Reload networking so the UCI policy-routing objects are applied.
/etc/init.d/network reload

# Reconcile the exact runtime objects needed by BSBF. This is intentionally
# idempotent and does not modify the main routing table or WAN default routes.
while ip rule del priority "$BSBF_RULE_PRIORITY" fwmark "$BSBF_MARK/$BSBF_MARK_MASK" lookup "$BSBF_TABLE" 2>/dev/null; do :; done
ip route del local 0.0.0.0/0 dev lo table "$BSBF_TABLE" 2>/dev/null || true
ip rule add priority "$BSBF_RULE_PRIORITY" fwmark "$BSBF_MARK/$BSBF_MARK_MASK" lookup "$BSBF_TABLE"
ip route add local 0.0.0.0/0 dev lo table "$BSBF_TABLE"

# Explicitly restart Xray after BSBF generated its final configuration.
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

if ! ss -lntup 2>/dev/null | grep -q "127.0.0.1:$BSBF_TPROXY_PORT"; then
	echo "Installation failed: Xray is enabled but is not listening on 127.0.0.1:$BSBF_TPROXY_PORT."
	echo "Run: /etc/init.d/xray status"
	echo "Run: logread -e xray"
	exit 1
fi

# Verify the live policy-routing state before declaring success.
if ! ip rule show | grep -Eq "^$BSBF_RULE_PRIORITY:.*fwmark $BSBF_MARK/$BSBF_MARK_MASK.*lookup $BSBF_TABLE$"; then
	echo "Installation failed: BSBF fwmark policy rule is missing."
	echo "Run: ip rule"
	exit 1
fi

if ! ip route show table "$BSBF_TABLE" | grep -Eq '^local 0.0.0.0/0 dev lo'; then
	echo "Installation failed: BSBF local TPROXY route is missing from table $BSBF_TABLE."
	echo "Run: ip route show table $BSBF_TABLE"
	exit 1
fi

if ! ip mptcp endpoint show 2>/dev/null | grep -q 'subflow'; then
	echo "Installation failed: no MPTCP subflow endpoint is configured."
	echo "Run: ip mptcp endpoint show"
	exit 1
fi

if ! nft list table ip bsbf_bonding >/dev/null 2>&1; then
	echo "Installation failed: BSBF nftables table is missing."
	echo "Run: nft list table ip bsbf_bonding"
	exit 1
fi

# Install an independent OpenWrt uninstaller.
curl -fsSL https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-bonding-openwrt-uninstall.sh \
	-o /usr/sbin/bsbf-bonding-openwrt-uninstall
chmod 755 /usr/sbin/bsbf-bonding-openwrt-uninstall

echo
echo "BSBF OpenWrt installation complete."
echo "Xray UCI: $(uci -q get xray.enabled.enabled)"
echo "Xray listener: 127.0.0.1:$BSBF_TPROXY_PORT"
echo "BSBF policy: fwmark $BSBF_MARK/$BSBF_MARK_MASK -> table $BSBF_TABLE"
echo "BSBF route: local 0.0.0.0/0 dev lo table $BSBF_TABLE"
echo "MPTCP endpoints:"
ip mptcp endpoint show 2>/dev/null || true
echo "Uninstall with: bsbf-bonding-openwrt-uninstall"
