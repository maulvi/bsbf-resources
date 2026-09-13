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
ip mptcp endpoint flush 2>/dev/null || ip mptcp endpoint flush all 2>/dev/null || true

# Remove policy-routing rules that explicitly use the BSBF TPROXY mark.
# Do not flush the complete rule table: OpenWrt may have unrelated rules.
log "Removing BSBF policy-routing rules."
while ip rule show | grep -Eq 'fwmark (0x)?0*1([ /].*)?'; do
	line=$(ip rule show | grep -E 'fwmark (0x)?0*1([ /].*)?' | head -n 1)
	pref=$(echo "$line" | sed -n 's/^\([0-9][0-9]*\):.*/\1/p')
	[ -n "$pref" ] || break
	ip rule del pref "$pref" 2>/dev/null || break
done

# Remove only routing tables that are commonly created for the BSBF TPROXY
# mark. Table 1 is handled explicitly because the previous integration used it.
for table in 1 100 101 102; do
	ip route flush table "$table" 2>/dev/null || true
done

# Remove BSBF runtime state.
rm -f /run/bsbf-mptcp-* 2>/dev/null || true

log "Removing BSBF package."
if apk info -e bsbf-bonding >/dev/null 2>&1; then
	apk del bsbf-bonding || true
fi

# Remove BSBF-owned configuration and init scripts left behind by older builds.
rm -rf /etc/bsbf /usr/share/bsbf 2>/dev/null || true
rm -f /etc/init.d/bsbf-mptcp /etc/init.d/bsbf-bonding-nft 2>/dev/null || true
rm -f /usr/sbin/bsbf-mptcp /usr/sbin/bsbf-mptcp-helper 2>/dev/null || true

# Xray may be used independently by the user, so do not blindly uninstall
# xray-core. Remove it only when apk reports it as an orphaned dependency.
if apk info -e xray-core >/dev/null 2>&1; then
	log "xray-core is still installed; leaving it untouched."
fi

rm -f /usr/sbin/bsbf-bonding-openwrt-uninstall 2>/dev/null || true

log "BSBF uninstall complete."
log "Verify with: ps | grep -E 'bsbf|xray' | grep -v grep"
log "Verify with: ip mptcp endpoint show"
log "Verify with: nft list tables | grep bsbf"
