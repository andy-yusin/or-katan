# or-katan

*אור קטן — "small light".*

A self-hosted routing gateway: **named ingress channels** for who connects, and
**named egress paths** for how their traffic leaves. You decide, per group and
per destination, which way out anything takes.

```
sudo ./install.sh
gw-client add "moms-phone" --channel family    # prints a QR; scan it
gw-egress                                      # where is everyone going out?
gw-doctor                                      # check every layer
```

## The model

```
   ingress channels                        egress paths
   ────────────────                        ────────────
   family   ──┐                        ┌──▶ main     (tunnel, exit abroad)
   friends  ──┼──▶  routing policy  ───┼──▶ backup   (tunnel, second exit)
   work     ──┘        + DNS           └──▶ direct   (this box's own uplink)
```

Each **ingress channel** is its own interface, UDP port, subnet and policy —
its own protocol, its own default egress, its own isolation rules, its own
client list. Give different groups different channels and you can route, isolate
and revoke them independently; a leaked config costs you one channel, not the
gateway.

Each **egress path** is a way out: the box's own uplink, or a tunnel you
terminate elsewhere so traffic appears to come from that machine. Point a
channel at one, and move it later with a single command, live.

**Destination policy** overrides the channel default per domain. Streaming out
the path in the right country, national services out the local uplink so they
stay fast and unblocked, everything else through the main exit. Matching is
per-domain, not per-CIDR: dnsmasq drops each answer into an ipset as it
resolves, so CDNs and rotating addresses are covered without maintaining lists.

Example — three groups, three ways out:

| Channel | Protocol | Isolated | Default egress |
|---|---|---|---|
| `family` | AmneziaWG (obfuscated) | no — devices see each other | `main` |
| `friends` | AmneziaWG | yes — internet only | `main` |
| `work` | WireGuard | no | `backup` |

plus a rule sending `stream.example` out a `uk` path and your bank out `direct`,
regardless of which channel asked.

## Two ingress protocols, on purpose

`wg` is plain WireGuard — fastest, first-party client on every platform. Its
weakness is that the handshake has a recognisable shape, and some mobile
carriers fingerprint and drop it. The failure is silent: the client shows a
tunnel, and nothing passes.

`awg` is [AmneziaWG](https://amnezia.org) — the same protocol with randomised
junk and rewritten headers, so it no longer matches that signature. It needs
Amnezia's client app rather than the stock one.

Running both means a blocked network is a config swap, not an outage. The
obfuscation signature is generated randomly per gateway, never copied from
another install — a shared signature would let one fingerprint identify every
gateway using it.

## DNS you cannot opt out of

Clients get AdGuardHome: ad and tracker filtering for every device, one place to
change a rule, per-client query stats. Port 53 is redirected to the gateway
whatever resolver the client configured, and DoT is rejected — so a device with
a hardcoded resolver still gets yours. Upstream is DoH via dnscrypt-proxy,
routed out whichever egress you choose, so the network this box sits on cannot
see what your clients look up.

## Requirements

- Ubuntu 22.04/24.04 or Debian 12, root access. A 1-core / 1 GB VPS is plenty.
- A DNS name pointing at it. Strongly preferred over a bare IP: the name is
  baked into every client config, so you can move the box and clients follow.
- One open UDP port per ingress channel.

## Install

```bash
git clone https://github.com/andy-yusin/or-katan.git
cd or-katan
cp gateway.conf.example gateway.conf
$EDITOR gateway.conf          # declare your channels and egress paths
sudo ./install.sh
```

The installer validates the whole config before touching anything — duplicate
ports, overlapping subnets, channels pointing at egress paths that do not exist.
Re-run it after any change: it never rotates keys and never drops clients.

## Daily use

| | |
|---|---|
| `gw-client add "laptop" --channel work` | new client, config + QR |
| `gw-client list` / `gw-client channels` | who exists, who is online, what is configured |
| `gw-client show "laptop"` | reprint a config and its QR |
| `gw-client remove "laptop"` | revoke, immediately |
| `gw-egress` | every path, its health, and who uses it |
| `gw-egress set family backup` | move one channel, live |
| `gw-egress set all direct` | move everything (e.g. an exit went down) |
| `gw-doctor` | check every layer |

Client configs land in `/etc/gateway/clients/`. They contain private keys — send
them over something end-to-end encrypted and delete your copy afterwards.

Clients on a non-isolated channel also get a `<name>.gw` name, so they can reach
each other by name.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the routing and DNS work
- [docs/CHANNELS.md](docs/CHANNELS.md) — designing channels, egress paths and policy
- [docs/EXIT-SERVER.md](docs/EXIT-SERVER.md) — standing up a tunnel egress
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — the failure modes worth knowing in advance

## Uninstall

```bash
sudo ./uninstall.sh            # keeps keys and clients
sudo ./uninstall.sh --purge    # deletes them; every issued config dies
```

To update, `git pull` and re-run `sudo ./install.sh`. Keys and clients survive.

## Contributing

Changes are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the house
rules, and [test/README.md](test/README.md) for the container harness that
installs the whole stack and checks it in about two minutes.

Security reports go to a [security advisory](../../security/advisories/new),
not a public issue. [SECURITY.md](SECURITY.md) covers what is worth knowing
before you run this.

## License

MIT — see [LICENSE](LICENSE).
