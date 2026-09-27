#!/bin/sh
set -eu

###############################################################################
# BSBF OpenWrt Installer
# OpenWrt 25.12+
###############################################################################

SERVER_IPV4="${1:-}"
SERVER_PORT="${2:-}"
UUID="${3:-}"
SERVER_NAME="${4:-default}"
SERVER_NAME="${4:-default}"

if [ -z "$SERVER_IPV4" ] || [ -z "$SERVER_PORT" ] || [ -z "$UUID" ]; then
    echo
    echo "Usage:"
    echo "  $0 192.0.2.10 6701 00000000-0000-0000-0000-000000000000 [name]"
    echo
    echo "Example:"
    echo "  $0 192.0.2.10 6701 00000000-0000-0000-0000-000000000000 [name]"
    echo
    exit 1
fi

echo "=============================================="
echo " BSBF OpenWrt Installer"
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
    kmod-tcp-bbr \
    xray-core \
    ss \
    kitty-terminfo

echo "[2/8] Stopping existing services..."
/etc/init.d/xray stop 2>/dev/null || true
/etc/init.d/bsbf-mptcp stop 2>/dev/null || true
nft destroy table bsbf_bonding 2>/dev/null || true

echo "[3/8] Configuring BSBF server..."
uclient-fetch -qO /usr/bin/bsbf-server https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-server
chmod 700 /usr/bin/bsbf-server
cat > /usr/bin/bsbf-server <<'BSBF_SERVER'
#!/bin/sh
set -eu

CONFIG="/etc/bsbf/servers.conf"
ACTIVE="/etc/bsbf/active-server"
BONDING="/etc/bsbf/bsbf-bonding.conf"
XRAY_TEMPLATE="/usr/share/bsbf/xray.json"
XRAY_CONFIG="/etc/xray/config.json"

die() { echo "ERROR: $*" >&2; exit 1; }

valid_name() {
    echo "$1" | grep -Eq '^[A-Za-z0-9._-]+mkdir -p /etc/bsbf
bsbf-server add "$SERVER_NAME" "$SERVER_IPV4" "$SERVER_PORT" "$UUID"
echo "$SERVER_NAME" > /etc/bsbf/active-server
chmod 600 /etc/bsbf/active-server
bsbf-server current

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
        j.outbounds[1].settings.redirect = sprintf("%s:%s", addr, port);
        fs.writefile(outfile, sprintf("%.2J\n", j));
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

nft -f /usr/share/bsbf/bsbf_bonding.nft

/etc/init.d/xray enable
/etc/init.d/bsbf-mptcp enable
/etc/init.d/bsbf-bonding-nft enable

/etc/init.d/bsbf-mptcp restart 2>/dev/null || true

killall xray 2>/dev/null || true
/etc/init.d/xray start
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
echo "===== SERVICES ====="
service xray status || true
service bsbf-mptcp status || true
bsbf-bonding --status

echo
echo "=============================================="
echo " BSBF INSTALLATION COMPLETE"
echo "=============================================="

}

ensure_files() {
    mkdir -p /etc/bsbf /etc/xray
    touch "$CONFIG"
    chmod 600 "$CONFIG"
}

find_server() {
    awk -F '|' -v n="$1" '$1 == n {print; exit}' "$CONFIG"
}

write_xray() {
    addr="$1"
    port="$2"
    id="$3"

    [ -f "$XRAY_TEMPLATE" ] || die "Xray template not found: $XRAY_TEMPLATE"

    ucode -l fs \
        -D infile="$XRAY_TEMPLATE" \
        -D outfile="$XRAY_CONFIG" \
        -D addr="$addr" \
        -D port="$port" \
        -D id="$id" \
        -e '
            let j = json(fs.readfile(infile));
            j.outbounds[0].settings.id = id;
            j.outbounds[1].settings.redirect = sprintf("%s:%s", addr, port);
            fs.writefile(outfile, sprintf("%.2J\n", j));
        '
    chmod 600 "$XRAY_CONFIG"
}

apply_server() {
    name="$1"
    line="$(find_server "$name")"
    [ -n "$line" ] || die "Server not found: $name"

    IFS='|' read -r _ addr port id <<EOF
$line
EOF

    cat > "$BONDING" <<EOF
server_ipv4="$addr"
server_port="$port"
uuid="$id"
EOF
    chmod 600 "$BONDING"

    write_xray "$addr" "$port" "$id"

    killall xray 2>/dev/null || true
    /etc/init.d/xray start
    sleep 2
    /etc/init.d/bsbf-mptcp restart 2>/dev/null || true

    echo "$name" > "$ACTIVE"
    chmod 600 "$ACTIVE"
}

cmd_list() {
    ensure_files
    active="$(cat "$ACTIVE" 2>/dev/null || true)"
    printf '%-18s %-39s %-7s %s\n' "NAME" "SERVER" "PORT" "STATUS"
    printf '%-18s %-39s %-7s %s\n' "------------------" "---------------------------------------" "-------" "------"
    awk -F '|' -v a="$active" '{
        status=($1 == a ? "active" : "standby");
        printf "%-18s %-39s %-7s %s\n", $1, $2, $3, status
    }' "$CONFIG"
}

cmd_add() {
    [ "$#" -eq 4 ] || die "Usage: bsbf-server add <name> <server_ipv4> <port> <uuid>"
    name="$1"; addr="$2"; port="$3"; id="$4"
    valid_name "$name" || die "Invalid server name: use letters, numbers, . , _ or -"
    echo "$port" | grep -Eq '^[0-9]+mkdir -p /etc/bsbf
bsbf-server add "$SERVER_NAME" "$SERVER_IPV4" "$SERVER_PORT" "$UUID"
echo "$SERVER_NAME" > /etc/bsbf/active-server
chmod 600 /etc/bsbf/active-server
bsbf-server current

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
        j.outbounds[1].settings.redirect = sprintf("%s:%s", addr, port);
        fs.writefile(outfile, sprintf("%.2J\n", j));
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

nft -f /usr/share/bsbf/bsbf_bonding.nft

/etc/init.d/xray enable
/etc/init.d/bsbf-mptcp enable
/etc/init.d/bsbf-bonding-nft enable

/etc/init.d/bsbf-mptcp restart 2>/dev/null || true

killall xray 2>/dev/null || true
/etc/init.d/xray start
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
echo "===== SERVICES ====="
service xray status || true
service bsbf-mptcp status || true
bsbf-bonding --status

echo
echo "=============================================="
echo " BSBF INSTALLATION COMPLETE"
echo "=============================================="
 || die "Invalid port"
    [ -n "$addr" ] || die "Server IPv4 is required"
    [ -n "$id" ] || die "UUID is required"

    ensure_files
    if find_server "$name" >/dev/null 2>&1; then
        awk -F '|' -v n="$name" -v a="$addr" -v p="$port" -v i="$id" \
            'BEGIN{OFS="|"} $1 == n {$2=a;$3=p;$4=i} {print}' "$CONFIG" > "$CONFIG.tmp"
        mv "$CONFIG.tmp" "$CONFIG"
        chmod 600 "$CONFIG"
        echo "Updated server: $name"
    else
        printf '%s|%s|%s|%s\n' "$name" "$addr" "$port" "$id" >> "$CONFIG"
        chmod 600 "$CONFIG"
        echo "Added server: $name"
    fi
}

cmd_use() {
    [ "$#" -eq 1 ] || die "Usage: bsbf-server use <name>"
    ensure_files
    apply_server "$1"
    echo "Active server: $1"
}

cmd_remove() {
    [ "$#" -eq 1 ] || die "Usage: bsbf-server remove <name>"
    name="$1"
    ensure_files
    find_server "$name" >/dev/null 2>&1 || die "Server not found: $name"
    active="$(cat "$ACTIVE" 2>/dev/null || true)"
    [ "$active" != "$name" ] || die "Cannot remove the active server; switch to another server first"

    awk -F '|' -v n="$name" '$1 != n' "$CONFIG" > "$CONFIG.tmp"
    mv "$CONFIG.tmp" "$CONFIG"
    chmod 600 "$CONFIG"
    echo "Removed server: $name"
}

cmd_current() {
    ensure_files
    active="$(cat "$ACTIVE" 2>/dev/null || true)"
    [ -n "$active" ] || die "No active server"
    line="$(find_server "$active")"
    [ -n "$line" ] || die "Active server entry is missing: $active"
    IFS='|' read -r name addr port id <<EOF
$line
EOF
    echo "Name:   $name"
    echo "Server: $addr"
    echo "Port:   $port"
    echo "UUID:   $id"
}

usage() {
    cat <<EOF
Usage:
  bsbf-server list
  bsbf-server add <name> <server_ipv4> <port> <uuid>
  bsbf-server use <name>
  bsbf-server current
  bsbf-server remove <name>

Examples:
  bsbf-server add sg 192.0.2.10 6701 00000000-0000-0000-0000-000000000000
  bsbf-server use sg
EOF
}

ensure_files

case "${1:-}" in
    list) cmd_list ;;
    add) shift; cmd_add "$@" ;;
    use) shift; cmd_use "$@" ;;
    current) cmd_current ;;
    remove) shift; cmd_remove "$@" ;;
    -h|--help|"") usage ;;
    *) die "Unknown command: $1" ;;
esac
BSBF_SERVER
chmod 700 /usr/bin/bsbf-server

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
        j.outbounds[1].settings.redirect = sprintf("%s:%s", addr, port);
        fs.writefile(outfile, sprintf("%.2J\n", j));
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

nft -f /usr/share/bsbf/bsbf_bonding.nft

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
echo "===== SERVICES ====="
service xray status || true
service bsbf-mptcp status || true
bsbf-bonding --status

echo
echo "=============================================="
echo " BSBF INSTALLATION COMPLETE"
echo "=============================================="
