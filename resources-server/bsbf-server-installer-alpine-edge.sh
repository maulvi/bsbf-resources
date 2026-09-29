#!/bin/sh
# BSBF Server Installer - Alpine Edge / IPv4 only / OpenRC
set -eu

XRAY_DIR=/usr/local/etc/xray-bsbf-bonding
LIMIT=16384
UNINSTALL=0

die() { echo "ERROR: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --client-limit)
            [ "$#" -ge 2 ] || die "Missing client limit"
            LIMIT="$2"; shift 2 ;;
        --uninstall)
            UNINSTALL=1; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Run as root"

if [ "$UNINSTALL" = 1 ]; then
    rc-service bsbf-mptcp-configuration stop 2>/dev/null || true
    for f in /etc/init.d/xray-bsbf-*; do
        [ -e "$f" ] || continue
        n=$(basename "$f")
        rc-service "$n" stop 2>/dev/null || true
        rc-update del "$n" default 2>/dev/null || true
        rm -f "$f"
    done
    rc-update del bsbf-mptcp-configuration default 2>/dev/null || true
    rm -f /etc/init.d/bsbf-mptcp-configuration
    rm -f /usr/local/sbin/bsbf-add-client /usr/local/sbin/bsbf-list-client
    rm -f /usr/local/sbin/bsbf-remove-client /usr/local/sbin/bsbf-rate-limiting
    rm -f /usr/local/sbin/bsbf-xray-client /usr/local/sbin/bsbf-register-xray
    rm -rf "$XRAY_DIR"
    echo "BSBF Alpine server uninstalled."
    exit 0
fi

case "$LIMIT" in *[!0-9]*) die "--client-limit must be numeric";; esac
[ "$LIMIT" -le 16384 ] || die "--client-limit must not exceed 16384"

echo "[1/6] Enabling Alpine Edge testing repository..."
grep -q '/alpine/edge/testing' /etc/apk/repositories 2>/dev/null ||
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

echo "[2/6] Installing packages..."
apk update
apk add ca-certificates curl findutils iproute2 iproute2-tc xray
update-ca-certificates

echo "[3/6] Checking MPTCP..."
ip mptcp limits show >/dev/null 2>&1 || die "Kernel does not expose MPTCP support"
mkdir -p "$XRAY_DIR"
curl -fsSL https://raw.githubusercontent.com/bondingshouldbefree/bsbf-resources/refs/heads/main/resources-server/core-config.json -o "$XRAY_DIR/core-config.json"
chmod 600 "$XRAY_DIR/core-config.json"

cat > /usr/local/sbin/bsbf-xray-client <<'EOF'
#!/bin/sh
set -eu
action="$1"
name="$2"
base=/usr/local/etc/xray-bsbf-bonding
pid=/run/bsbf-xray-$name.pid
case "$action" in
start)
    if [ -f "$pid" ] && kill -0 "$(cat "$pid")" 2>/dev/null; then exit 0; fi
    start-stop-daemon --start --background --make-pidfile --pidfile "$pid"         --exec /usr/bin/xray -- run -config "$base/core-config.json" -config "$base/$name.json"
    ;;
stop)
    [ -f "$pid" ] && kill "$(cat "$pid")" 2>/dev/null || true
    rm -f "$pid"
    ;;
esac
EOF
chmod +x /usr/local/sbin/bsbf-xray-client

cat > /usr/local/sbin/bsbf-register-xray <<'EOF'
#!/bin/sh
set -eu
name="$1"
svc=/etc/init.d/xray-bsbf-$name
cat > "$svc" <<EORC
#!/sbin/openrc-run
command="/usr/local/sbin/bsbf-xray-client"
command_args="start $name"
command_stop="/usr/local/sbin/bsbf-xray-client"
command_stop_args="stop $name"
pidfile="/run/bsbf-xray-$name.pid"
depend() { need net; }
EORC
chmod +x "$svc"
rc-update add xray-bsbf-$name default >/dev/null 2>&1 || true
EOF
chmod +x /usr/local/sbin/bsbf-register-xray

cat > /usr/local/sbin/bsbf-add-client <<EOF
#!/bin/sh
set -eu
speed="$1"
base=16384
limit=$LIMIT
uuid=$(xray uuid)
id=$base
while find $XRAY_DIR -maxdepth 1 -name "$id-*.json" -print -quit | grep -q .; do id=$((id + 1)); done
[ "$id" -lt $((base + limit)) ] || { echo "Client limit reached" >&2; exit 1; }
port="$id"
outmark=$((id + 16384))
file="$XRAY_DIR/$port-$uuid-$speed.json"
cat > "$file" <<JSON
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {"clients": [{"id": "$uuid"}], "decryption": "none"},
    "streamSettings": {"sockopt": {"mark": $id, "tcpMptcp": true}}
  }],
  "outbounds": [{
    "protocol": "freedom",
    "streamSettings": {"sockopt": {"mark": $outmark}}
  }]
}
JSON
name="$port-$uuid-$speed"
bsbf-register-xray "$name"
rc-service xray-bsbf-$name start
iface=$(ip route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[ -z "$iface" ] || [ "$speed" -eq 0 ] || bsbf-rate-limiting "$iface" >/dev/null 2>&1 || true
echo "$port $uuid"
EOF
chmod +x /usr/local/sbin/bsbf-add-client

cat > /usr/local/sbin/bsbf-list-client <<'EOF'
#!/bin/sh
for file in /usr/local/etc/xray-bsbf-bonding/[0-9]*-*.json; do
    [ -e "$file" ] || continue
    f=$(basename "$file" .json)
    port=$(echo "$f" | cut -d- -f1)
    speed=$(echo "$f" | awk -F- '{print $NF}')
    uuid=$(echo "$f" | cut -d- -f2- | sed 's/-[^-]*$//')
    echo "$port $uuid $speed"
done | sort -n
EOF
chmod +x /usr/local/sbin/bsbf-list-client

cat > /usr/local/sbin/bsbf-remove-client <<'EOF'
#!/bin/sh
set -eu
[ "$#" -gt 0 ] || exit 1
for input in "$@"; do
    for file in /usr/local/etc/xray-bsbf-bonding/"$input"-*.json /usr/local/etc/xray-bsbf-bonding/*-"$input"-*.json; do
        [ -e "$file" ] || continue
        name=$(basename "$file" .json)
        rc-service xray-bsbf-"$name" stop 2>/dev/null || true
        rc-update del xray-bsbf-"$name" default 2>/dev/null || true
        rm -f "$file" /etc/init.d/xray-bsbf-"$name"
        iface=$(ip route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
        [ -z "$iface" ] || bsbf-rate-limiting "$iface" >/dev/null 2>&1 || true
    done
done
EOF
chmod +x /usr/local/sbin/bsbf-remove-client


cat > /usr/local/sbin/bsbf-rate-limiting <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 1 ] || exit 1
iface="$1"
tc qdisc replace dev "$iface" root handle 1:0 htb
for file in /usr/local/etc/xray-bsbf-bonding/[0-9]*-*.json; do
    [ -e "$file" ] || continue
    f=$(basename "$file" .json)
    id=$(echo "$f" | cut -d- -f1)
    speed=$(echo "$f" | awk -F- '{print $NF}')
    [ "$speed" -gt 0 ] || continue
    inhex=$(printf '%x' "$id")
    outhex=$(printf '%x' "$((id + 16384))")
    tc class add dev "$iface" parent 1:0 classid 1:$inhex htb rate "$speed"mbit 2>/dev/null || true
    tc class add dev "$iface" parent 1:0 classid 1:$outhex htb rate "$speed"mbit 2>/dev/null || true
    tc filter add dev "$iface" parent 1:0 handle 0x$inhex fw classid 1:$inhex 2>/dev/null || true
    tc filter add dev "$iface" parent 1:0 handle 0x$outhex fw classid 1:$outhex 2>/dev/null || true
done
EOF
chmod +x /usr/local/sbin/bsbf-rate-limiting

echo "[4/6] Configuring MPTCP OpenRC service..."
cat > /etc/init.d/bsbf-mptcp-configuration <<'EOF'
#!/sbin/openrc-run
description="BSBF MPTCP configuration"
depend() { need net; }
start() {
    ip mptcp limits set subflows 8
    sysctl -w net.mptcp.blackhole_timeout=0 >/dev/null 2>&1 || true
    sysctl -w net.mptcp.syn_retrans_before_tcp_fallback=128 >/dev/null 2>&1 || true
}
EOF
chmod +x /etc/init.d/bsbf-mptcp-configuration
rc-update add bsbf-mptcp-configuration default
rc-service bsbf-mptcp-configuration start

echo "[5/6] Validating Xray and MPTCP..."
xray version
ip mptcp limits show
rc-service bsbf-mptcp-configuration status

echo "[6/6] Installation complete."
echo
echo "Add client:    bsbf-add-client 50"
echo "List clients:  bsbf-list-client"
echo "Remove client: bsbf-remove-client <PORT|UUID>"
echo
echo "BSBF Alpine Edge server is ready."
