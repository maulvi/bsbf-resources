# BondingShouldBeFree (BSBF)

BondingShouldBeFree is a network bonding solution based on **Multipath TCP (MPTCP)**. It combines multiple independent Internet connections into a single logical connection, improving aggregate throughput and providing redundancy when one connection becomes unavailable.

BSBF uses an upstream Linux kernel MPTCP implementation and is designed for conventional Linux distributions and devices supported by [OpenWrt](https://openwrt.org/).

## How it works

A BSBF deployment consists of a **client** and a **server**:

```text
Internet connection 1 ─┐
                       ├─ OpenWrt/Linux client ── MPTCP ── VPS server ── Internet
Internet connection 2 ─┘
```

The client establishes MPTCP subflows over its available WAN interfaces. The VPS terminates the aggregated connection and provides the remote Internet breakout.

BSBF is not conventional Ethernet bonding. It operates at the transport layer using MPTCP and can aggregate connections from different upstream networks.

## Project Documentation

- [BSBF introduction — dark background](https://github.com/bondingshouldbefree/.github/blob/main/profile/include/bsbf_bonding.pdf)
- [BSBF introduction — light background](https://github.com/bondingshouldbefree/.github/blob/main/profile/include/bsbf_bonding_light.pdf)
- [Project documentation](https://github.com/bondingshouldbefree/.github/blob/main/profile/documentation.md)
- [Knowledgebase and development logs](https://arinc9.notion.site/BondingShouldBeFree-KnowledgeBase-eb6710bfdf9544ffa6d57de510f404b1)
- [Tested OpenWrt devices](https://github.com/bondingshouldbefree/.github/blob/main/profile/tested-openwrt-devices.md)

## Support Community

- [Discord](https://discord.gg/7PQYdWT69x) — usage, projects, discussions, and hardware advice.

## Client Installation

### Conventional Linux distributions

Replace the server IPv4 address, server port, and UUID with the values created for your client:

```sh
curl -fsSL https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-client-installer.sh | sudo sh -s -- --server-ipv4 25.0.0.1 --server-port 16384 --uuid 60d210ef-7271-4dc9-9b93-01563608bf90
```

The installer can be run again to change the server configuration or upgrade the installed solution.

Uninstall:

```sh
sudo bsbf-bonding --uninstall
```

### OpenWrt 25.12+

OpenWrt 25.12 uses `apk` for package management. The OpenWrt client uses **Xray as part of the BSBF TPROXY path**; do not remove `xray-core` while BSBF is installed. The `bsbf-bonding` package pulls the required Xray dependency.

Install BSBF directly from this repository:

```sh
apk add curl && curl -fsSL https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-client-openwrt-installer.sh | sh -s -- --server-ipv4 25.0.0.1 --server-port 16384 --uuid 60d210ef-7271-4dc9-9b93-01563608bf90
```

The installer can be run again to change the server configuration or upgrade the installed solution.

#### What the OpenWrt installation configures

The OpenWrt integration configures the following components:

- `bsbf-bonding`
- `bsbf-mptcp`
- `bsbf-bonding-nft`
- `xray-core`
- Xray TPROXY listener on `127.0.0.1:12345`
- nftables TPROXY rules in `ip bsbf_bonding`
- packet mark `1` for intercepted traffic
- policy routing from `fwmark 1` to routing table `1`
- a local route in table `1` so TPROXY traffic is delivered to the local Xray listener
- MPTCP endpoints for the available WAN interfaces

The important traffic path is:

```text
LAN client
   │
   ▼
nftables TPROXY
   │ mark 1
   ▼
ip rule: fwmark 1 → table 1
   │
   ▼
Xray 127.0.0.1:12345
   │
   ▼
BSBF / MPTCP
   ├── WAN 1
   └── WAN 2
   │
   ▼
BSBF VPS
```

Verify the installation:

```sh
ss -lntup | grep 12345
ip mptcp endpoint show
ip rule
ip route show table 1
nft list table ip bsbf_bonding
```

A healthy installation should show Xray listening on `127.0.0.1:12345`, MPTCP endpoints for the WAN interfaces, a policy rule for mark `1`, and a local route in table `1`.

If `ip mptcp endpoint show` works but LAN clients cannot access the Internet while BSBF is enabled, check the complete TPROXY path rather than MPTCP alone:

```sh
ss -lntup | grep 12345
ip rule
ip route show table 1
nft list chain ip bsbf_bonding prerouting_mangle
logread | grep -Ei 'xray|bsbf|mptcp'
```

### OpenWrt uninstall

Use the BSBF OpenWrt uninstaller so runtime state and the Xray dependency are cleaned up together:

```sh
bsbf-bonding-openwrt-uninstall
```

If the command is not available, run the repository uninstaller directly:

```sh
curl -fsSL https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-bonding-openwrt-uninstall.sh | sh
```

The OpenWrt uninstaller removes:

- BSBF services and startup entries
- Xray service and `xray-core`
- the `bsbf_bonding` nftables table
- BSBF MPTCP endpoints
- BSBF TPROXY policy-routing rules
- BSBF routing state
- BSBF/Xray configuration and runtime files

It intentionally does **not** blindly delete unrelated WAN/LAN configuration. Review your network configuration if BSBF installation previously changed interface layout.

Verify after uninstall:

```sh
ps | grep -E 'bsbf|xray' | grep -v grep
ip mptcp endpoint show
ip rule
nft list tables | grep bsbf
```

If the device runs out of storage, build a firmware image using the [BondingShouldBeFree firmware selector](https://fs.bondingshouldbefree.org/).

## Server Installation

Install or upgrade the BSBF server directly from this repository:

```sh
curl -fsSL https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-server/bsbf-server-installer.sh | sudo sh
```

Add a client with a 50 Mbps download and upload limit:

```sh
sudo bsbf-add-client 50
```

The command returns the server port and UUID assigned to the client, for example:

```text
16384 60d210ef-7271-4dc9-9b93-01563608bf90
```

Use `0` instead of `50` for an unlimited download or upload direction.

Remove a client by port, port range, or UUID:

```sh
sudo bsbf-remove-client 16384
sudo bsbf-remove-client 16384-16400
sudo bsbf-remove-client 60d210ef-7271-4dc9-9b93-01563608bf90
```

Uninstall the server directly from this repository:

```sh
curl -fsSL https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-server/bsbf-server-installer.sh | sudo sh -s -- --uninstall
```

## Direct Raw Resources

The installers and runtime resources are available directly from GitHub without requiring a separate download domain.

### Linux Client Installer

```text
https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-client-installer.sh
```

### OpenWrt Client Installer

```text
https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-client-openwrt-installer.sh
```

### OpenWrt Uninstaller

```text
https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-bonding-openwrt-uninstall.sh
```

### Server Installer

```text
https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-server/bsbf-server-installer.sh
```

### OpenWrt BSBF Bonding Configuration

```text
https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf_bonding.nft
```

### OpenWrt Xray Configuration

```text
https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/xray.json
```

### MPTCP Manager

```text
https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-mptcp
```

### MPTCP Helper

```text
https://raw.githubusercontent.com/maulvi/bsbf-resources/main/resources-client/bsbf-mptcp-helper
```

## Architecture

```text
                    Internet
                       │
          ┌────────────┴────────────┐
          │                         │
       WAN 1                     WAN 2
          │                         │
          └──────────┬──────────────┘
                     │
                BSBF Client
                  OpenWrt
                     │
               Xray TPROXY
                     │
                   MPTCP
                     │
              Encrypted Tunnel
                     │
                     ▼
                BSBF VPS
                     │
                  Internet
```

The OpenWrt client establishes the BSBF connection to the user's VPS. Xray is the transparent-proxy component used by the OpenWrt BSBF integration; MPTCP provides the multi-WAN transport aggregation.

## Requirements

### OpenWrt

- OpenWrt 25.12 or newer
- `apk` package manager
- Linux kernel with MPTCP support
- `kmod-nft-tproxy`
- `xray-core` (installed as a BSBF dependency)
- At least two Internet connections for bonding
- Reachable BSBF VPS
- Valid BSBF server port
- Valid client UUID

### Server

- Linux server/VPS
- Public IPv4 address
- Required BSBF server port reachable from the Internet
- MPTCP-capable Linux kernel

## Security

Do not publish client UUIDs or other private credentials in public repositories.

The client UUID is used to identify the BSBF client when connecting to the BSBF server.

## Troubleshooting

### Xray is not listening on port 12345

Check:

```sh
/etc/init.d/xray status
xray run -test -config /etc/xray/config.json
logread | grep -Ei 'xray|procd'
```

If the configuration is valid but Xray is stopped:

```sh
/etc/init.d/xray restart
```

### MPTCP endpoints are present but traffic is not passing

Check the entire TPROXY path:

```sh
ss -lntup | grep 12345
ip mptcp endpoint show
ip rule
ip route show table 1
nft list table ip bsbf_bonding
```

The presence of MPTCP endpoints alone does not establish a working TPROXY path. Intercepted traffic must be marked, routed through table `1`, delivered to the local Xray TPROXY listener, and then sent through the BSBF/MPTCP transport.

### `ip rule` does not contain the BSBF mark rule

The OpenWrt BSBF integration requires a policy rule equivalent to:

```text
fwmark 1 lookup 1
```

and table `1` should contain the local route used by the TPROXY integration. If these are missing, reinstall or re-enable BSBF rather than manually adding unrelated routes.

### MPTCP helper reports `too many addresses or duplicate one: -17`

`-17` is `EEXIST`: the endpoint already exists. The endpoint should not be added twice.

## License

See the individual source files for their applicable SPDX license information.
