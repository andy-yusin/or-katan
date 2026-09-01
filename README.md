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

## What it is for

A hub where many connections meet and each one is routed deliberately. Three
shapes come up over and over:

**Several VPNs at once, on one box.** Three customers, three VPNs, and a laptop
that can only hold one at a time. Terminate all of them on the gateway and route
by destination instead: project A's staging and project B's git are reachable
simultaneously, from every machine behind it, with nothing to toggle. The `dev`
profile is this shape.

**A small office or team.** One channel per group — staff, contractors, lab
gear, personal devices. Each gets its own subnet, its own default exit, and its
own isolation rules, so contractors reach the internet and nothing else while
staff reach the printer. Revoking a group is one channel, not a rebuild.

**A household.** Phones and laptops on an obfuscated channel, guests isolated,
IoT devices on their own channel that can talk to the internet and to nothing of
yours. Filtered DNS for everyone, with the things that should see your own
address — bank, tax portal — sent straight out.

What they have in common: more than one way in, more than one way out, and a
decision about which pairs with which. If that is the problem, this is the tool.
If you want one tunnel for one person, plain WireGuard is simpler and you should
use it.

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

- Ubuntu 22.04/24.04 or Debian 12, root access. A 1-core / 512 MB VPS is plenty.
- A DNS name pointing at it. Strongly preferred over a bare IP: the name is
  baked into every client config, so you can move the box and clients follow.
- One open UDP port per ingress channel.

## Install

```bash
git clone https://github.com/andy-yusin/or-katan.git
cd or-katan
sudo ./setup.sh
```

`setup.sh` asks what you want, writes `gateway.conf`, and offers to install.
Every question has a default and nothing is written until the end. To write the
config by hand instead, start from `gateway.conf.example` and run
`sudo ./install.sh`.

The installer validates the whole config before touching anything — duplicate
ports, overlapping subnets, channels pointing at egress paths that do not exist.
Re-run it after any change: it never rotates keys and never drops clients.

Full prerequisites, what the installer does step by step, and how to verify it
worked: [docs/INSTALL.md](docs/INSTALL.md).

### Profiles

A profile is a ready-made destination policy you can apply at any time:

```bash
gw-config profiles           # what is available
gw-config profile ru         # apply one
```

`none`, `split-home`, and `ru` ship with it; writing your own is a text file.
See [profiles/README.md](profiles/README.md).

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
| `gw-egress add uk --endpoint …` | declare a new exit; generates a key if you omit one |
| `gw-egress remove uk` | drop one nothing points at |
| `gw-config` | the whole configuration, grouped |
| `gw-config set DNS_FILTER_ENABLE no` | change one setting, validated and applied |
| `gw-config profile ru` | swap the destination policy wholesale |
| `gw-doctor` | check every layer |

Anything that changes the config validates first and rolls back if the result
would not install, so a typo cannot take the gateway down.

Client configs land in `/etc/gateway/clients/`. They contain private keys — send
them over something end-to-end encrypted and delete your copy afterwards.

Clients on a non-isolated channel also get a `<name>.gw` name, so they can reach
each other by name.

## Documentation

- [docs/INSTALL.md](docs/INSTALL.md) — prerequisites, the install itself, and verifying it
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the routing and DNS work
- [docs/CHANNELS.md](docs/CHANNELS.md) — designing channels, egress paths and policy
- [docs/EXIT-SERVER.md](docs/EXIT-SERVER.md) — standing up a tunnel egress
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — the failure modes worth knowing in advance
- [profiles/README.md](profiles/README.md) — ready-made destination policies
- [AGENTS.md](AGENTS.md) — the map, if you are pointing an assistant at this repo

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
