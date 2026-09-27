#!/bin/sh
set -eu

###############################################################################
# BSBF OpenWrt Installer
# OpenWrt 25.12+
###############################################################################

SERVER_IPV4="${1:-}"
SERVER_PORT="${2:-}"
UUID="${3:-}"

if [ -z "$SERVER_IPV4" ] || [ -z "$SERVER_PORT" ] || [ -z "$UUID" ]; then
    echo
    echo "Usage:"
    echo "  $0 <SERVER_IPV4> <SERVER_PORT> <UUID>"
    echo
    echo "Example:"
    echo "  $0 103.179.44.36 6701 286abec0-9ed9-4401-887a-4da334b0f23f"
    echo
    exit 1
fi

echo "=============================================="
echo " BSBF OpenWrt Installer"
 echo " DNS: DIRECT / BSBF: BONDED"
echo "=============================================="

echo "[1/8] Installing packages..."
apk update >/dev/null 2>&1 || true
apk add \
    bsbf-bonding \
    bsbf-client-web \
    bsbf-mptcp \
    bsbf-rate-limiting \
    kmod-nf-tproxy \
    kmod-nft-tproxy \
    xray-core

echo "[2/8] Stopping existing services..."
/etc/init.d/xray stop 2>/dev/null || true
/etc/init.d/bsbf-mptcp stop 2>/dev/null || true
nft destroy table bsbf_bonding 2>/dev/null || true

echo "[3/8] Configuring BSBF server..."
mkdir -p /etc/bsbf
cat > /etc/bsbf/bsbf-bonding.conf <<CONFIG
server_ipv4="$SERVER_IPV4"
server_port="$SERVER_PORT"
uuid="$UUID"
CONFIG
chmod 600 /etc/bsbf/bsbf-bonding.conf

echo "[4/8] Configuring Xray..."
mkdir -p /etc/xray

uci -q delete xray.enabled 2>/dev/null || true
uci -q delete xray.config 2>/dev/null || true

uci set xray.enabled='xray'
uci set xray.enabled.enabled='1'
uci set xray.config='xray'
uci set xray.config.confdir='/etc/xray'
uci set xray.config.conffiles='/etc/xray/config.json'
uci set xray.config.format='json'
uci commit xray

echo "[5/8] Generating Xray configuration..."
ucode -l fs \
    -D infile="/usr/share/bsbf/xray.json" \
    -D outfile="/etc/xray/config.json" \
    -D addr="$SERVER_IPV4" \
    -D port="$SERVER_PORT" \
    -D id="$UUID" \
    -e '
        let j = json(fs.readfile(infile));
        j.outbounds[0].settings.id = id;
        j.outbounds[1].settings.redirect = \`\${addr}:\${port}\`;
        fs.writefile(outfile, sprintf("%.2J\\n", j));
    '
chmod 600 /etc/xray/config.json

echo "[6/8] Configuring policy routing..."

# Remove only BSBF rules/routes by their explicit name where supported.
uci -q delete network.bsbf_tproxy 2>/dev/null || true
uci -q delete network.bsbf_tproxy_route 2>/dev/null || true

# Remove legacy/duplicate fwmark-1 rules and table-1 routes.
for section in $(uci show network 2>/dev/null | grep "option mark '1'" | cut -d. -f2); do
    [ -n "$section" ] && uci delete "network.$section" || true
done

for section in $(uci show network 2>/dev/null | grep "option table '1'" | cut -d. -f2); do
    [ -n "$section" ] && uci delete "network.$section" || true
done

uci add network rule >/dev/null
uci set network.@rule[-1].name='bsbf_tproxy'
uci set network.@rule[-1].priority='100'
uci set network.@rule[-1].mark='1'
uci set network.@rule[-1].lookup='1'

uci add network route >/dev/null
uci set network.@route[-1].name='bsbf_tproxy_route'
uci set network.@route[-1].interface='loopback'
uci set network.@route[-1].type='local'
uci set network.@route[-1].target='0.0.0.0/0'
uci set network.@route[-1].table='1'

uci commit network

echo "[7/8] Configuring BSBF services..."
/etc/init.d/network reload
sleep 2

# Use the official BSBF nft rules, but remove DNS interception.
# DNS therefore stays on the normal OpenWrt/WAN resolver path.
BSBF_NFT="/usr/share/bsbf/bsbf_bonding.nft"
sed -i '/th dport 53 tproxy ip to 127.0.0.1:12345 meta mark set 0x00000001/d' "$BSBF_NFT"
nft -f "$BSBF_NFT"

/etc/init.d/xray enable
/etc/init.d/bsbf-mptcp enable
/etc/init.d/bsbf-bonding-nft enable

/etc/init.d/bsbf-mptcp restart 2>/dev/null || true

killall xray 2>/dev/null || true
/etc/init.d/xray restart
sleep 3

echo "[8/8] Validating installation..."
nft -f /usr/share/bsbf/bsbf_bonding.nft

echo
echo "===== XRAY ====="
ps | grep '[x]ray' || {
    echo "ERROR: Xray is not running"
    exit 1
}
ss -lntup | grep ':12345' || {
    echo "ERROR: Xray is not listening on 12345"
    exit 1
}

echo
echo "===== POLICY ROUTING ====="
ip rule
echo
echo "===== TABLE 1 ====="
ip route show table 1

echo
echo "===== BSBF NFT ====="
nft list table ip bsbf_bonding

echo
echo "===== DNS CHECK ====="
echo "DNS port 53 is NOT intercepted by BSBF TPROXY."
echo "DNS uses the normal OpenWrt/WAN resolver path."
echo
echo "===== SERVICES ====="
service xray status || true
service bsbf-mptcp status || true
bsbf-bonding --status

echo
echo "=============================================="
echo " BSBF INSTALLATION COMPLETE"
echo " DNS: DIRECT"
echo " TRAFFIC: BONDED"
echo "=============================================="
