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

BSBF is therefore not conventional Ethernet bonding: it operates at the transport layer using MPTCP and can aggregate connections from different upstream networks.

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
curl -fsSL cld.bondingshouldbefree.org | sudo sh -s -- \
  --server-ipv4 25.0.0.1 \
  --server-port 16384 \
  --uuid 60d210ef-7271-4dc9-9b93-01563608bf90
```

The installer can be run again to change the server configuration or upgrade the installed solution.

Uninstall:

```sh
sudo bsbf-bonding --uninstall
```

### OpenWrt 25.12+

OpenWrt 25.12 uses `apk` for package management. Install BSBF with:

```sh
apk add curl && curl -fsSL owrt.bondingshouldbefree.org | sh -s -- \
  --server-ipv4 25.0.0.1 \
  --server-port 16384 \
  --uuid 60d210ef-7271-4dc9-9b93-01563608bf90
```

The installer configures the client credentials and installs the required OpenWrt packages. It can be run again to change the server configuration or upgrade the solution.

After installation, verify the services and MPTCP endpoints:

```sh
/etc/init.d/xray start
/etc/init.d/bsbf-bonding-nft start
/etc/init.d/bsbf-mptcp restart

ss -lntup | grep 12345
ip mptcp endpoint show
nft list table ip bsbf_bonding
```

For a working TPROXY setup, Xray must be listening on `127.0.0.1:12345`, the BSBF nftables table must be loaded, and policy routing for the TPROXY mark must be installed by the OpenWrt integration.

If `ip mptcp endpoint show` already contains endpoints but Internet traffic stops when BSBF is enabled, check the Xray listener and policy-routing state first:

```sh
ip rule
ip route show table 1
ss -lntup | grep 12345
```

A healthy TPROXY configuration normally has a rule for the BSBF mark and a local default route in the corresponding policy-routing table.

Uninstall:

```sh
bsbf-bonding --uninstall
```

> **Note:** uninstalling the BSBF package does not automatically restore changes previously made to the OpenWrt network configuration.

If the device runs out of storage, build a firmware image using the [BondingShouldBeFree firmware selector](https://fs.bondingshouldbefree.org/).

For generated OpenWrt images, the interface with the largest numeric suffix (for example `lan5`) is selected as LAN. If no interface has a numeric suffix, the first detected LAN interface is used. Other detected interfaces are configured as WAN interfaces.

## Server Installation

Install or upgrade the BSBF server:

```sh
curl -fsSL srv.bondingshouldbefree.org | sudo sh
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

Uninstall the server:

```sh
curl -fsSL https://github.com/bondingshouldbefree/bsbf-resources/raw/main/resources-server/bsbf-server-installer.sh \
  | sudo sh -s -- --uninstall
```

## Repository Layout

- `resources-client/` — client-side scripts, MPTCP helper, Xray configuration, nftables configuration, and OpenWrt/Linux resources.
- `resources-server/` — VPS/server installation, client management, MPTCP configuration, and rate-limiting resources.

## Troubleshooting

### MPTCP endpoints are present but traffic is not passing

Check:

```sh
ip mptcp endpoint show
ip rule
ip route show table 1
ss -lntup | grep 12345
nft list table ip bsbf_bonding
```

The presence of MPTCP endpoints alone does not establish a working TPROXY path. Traffic redirected by nftables must reach the local Xray TPROXY listener and the packet mark must have a matching policy-routing rule.

### Xray starts and immediately exits

Validate the configuration directly:

```sh
xray run -test -config /etc/xray/config.json
```

Then inspect the OpenWrt service configuration and logs:

```sh
/etc/init.d/xray start
/etc/init.d/xray status
logread | grep -Ei 'xray|procd'
```

### MPTCP helper reports `too many addresses or duplicate one: -17`

`-17` is `EEXIST`: the endpoint already exists. The MPTCP helper is intended to be idempotent and should not fail merely because the same interface endpoint is already registered.

## License

See the individual source files for their applicable SPDX license information.
