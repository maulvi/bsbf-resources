#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Chester A. Unal <chester.a.unal@arinc9.com>

set -u

log() {
	echo "[bsbf-uninstall] $*"
}

[ "$(id -u)" -eq 0 ] || {
	echo "Run this script as root."
	exit 1
}

log "Stopping BSBF services."
for service in xray bsbf-mptcp bsbf-bonding-nft; do
	[ -x "/etc/init.d/$service" ] && /etc/init.d/$service stop 2>/dev/null || true
	[ -x "/etc/init.d/$service" ] && /etc/init.d/$service disable 2>/dev/null || true
done

log "Removing BSBF nftables rules."
nft destroy table ip bsbf_bonding 2>/dev/null || true

log "Flushing BSBF MPTCP endpoints."
ip mptcp endpoint flush 2>/dev/null || ip mp e f 2>/dev/null || true
rm -f /run/bsbf-mptcp-* 2>/dev/null || true

# Remove only the policy-routing objects created by this installer.
# Keep unrelated OpenWrt routing rules and routes intact.
log "Removing BSBF policy-routing configuration."
uci -q delete network.bsbf_tproxy_rule 2>/dev/null || true
uci -q delete network.bsbf_tproxy_route 2>/dev/null || true
uci commit network 2>/dev/null || true

# Remove the exact runtime rule installed by this repository if it is still present.
ip rule del priority 100 fwmark 1 lookup 1 2>/dev/null || true
ip rule del priority 100 fwmark 0x1/0xff lookup 1 2>/dev/null || true

# Remove only the BSBF local route from table 1. Do not flush the entire table,
# because table 1 may contain user-created routes.
ip route del local 0.0.0.0/0 dev lo table 1 2>/dev/null || true

log "Removing BSBF package."
if apk info -e bsbf-bonding >/dev/null 2>&1; then
	apk del bsbf-bonding || true
fi

log "Removing Xray package."
if apk info -e xray-core >/dev/null 2>&1; then
	apk del xray-core || true
fi

log "Removing BSBF/Xray configuration and legacy files."
rm -rf /etc/bsbf /etc/xray /usr/share/bsbf 2>/dev/null || true
rm -f /etc/config/xray 2>/dev/null || true
rm -f /etc/init.d/bsbf-mptcp /etc/init.d/bsbf-bonding-nft /etc/init.d/xray 2>/dev/null || true
rm -f /usr/sbin/bsbf-mptcp /usr/sbin/bsbf-mptcp-helper /usr/sbin/bsbf-bonding 2>/dev/null || true
rm -f /usr/sbin/bsbf-bonding-openwrt-uninstall 2>/dev/null || true

# Reload the network configuration after removing the UCI entries.
/etc/init.d/network reload 2>/dev/null || true
sync

log "BSBF and Xray uninstall complete."
log "Verify with: ps | grep -E 'bsbf|xray' | grep -v grep"
log "Verify with: ip mptcp endpoint show"
log "Verify with: ip rule"
log "Verify with: nft list tables | grep bsbf"
