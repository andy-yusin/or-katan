# or-katan

*אור קטן — "small light".*

[![tests](https://github.com/andy-yusin/or-katan/actions/workflows/test.yml/badge.svg)](https://github.com/andy-yusin/or-katan/actions/workflows/test.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![platform: Debian/Ubuntu](https://img.shields.io/badge/platform-Debian%2012%20%7C%20Ubuntu%2022.04%2B-A81D33.svg)](docs/INSTALL.md)
[![WireGuard + AmneziaWG](https://img.shields.io/badge/tunnels-WireGuard%20%2B%20AmneziaWG-88171A.svg)](#two-ingress-protocols-on-purpose)
![shell: bash](https://img.shields.io/badge/shell-bash-4EAA25.svg)

A self-hosted routing gateway: **named ingress channels** for who connects, and
**named egress paths** for how their traffic leaves. You decide, per group and
per destination, which way out anything takes.

## Quickstart

Five minutes to a working gateway, on a fresh Ubuntu 24.04 or Debian 12 box you
have root on. This path is single-hop — everything leaves through the box's own
uplink — because that needs nothing you do not already have. Exits abroad,
extra channels and destination policy all bolt on afterwards without disturbing
anyone who is already connected.

**1. Install.**

```bash
git clone https://github.com/andy-yusin/or-katan.git
cd or-katan
sudo ./setup.sh
```

Answer the questions or press enter through them. The defaults give you one
channel called `family` on UDP 51820, filtered DNS, and no policy. It prints
the ports to forward when it finishes.

**2. Let clients reach it.** Open **UDP 51820** — in your VPS provider's
firewall, or as a port forward on the router to this box's LAN address. This is
the step people forget, and the symptom is a client that never handshakes.

**3. Add someone.**

```bash
sudo gw-client add "moms-phone" --channel family
```

A QR code is printed. Scan it with the **WireGuard** app — or the **AmneziaWG**
app if you chose an `awg` channel; the two are not interchangeable.

**4. Check it.**

```bash
gw-doctor        # every layer, in order — the first failure is the real one
gw-egress test   # asks the kernel where each channel's traffic actually goes
```

`gw-egress test` is the one that matters: it catches a leak that a working
internet connection would otherwise hide.

### Then, when you want more

```bash
sudo gw-egress add uk --endpoint <host>:<port> --pubkey <key> --address 10.2.0.2/24
sudo gw-config apply                  # bring the new exit up
sudo gw-egress set family uk          # send a channel through it, live

sudo gw-config profile split-home     # route some destinations differently
sudo gw-client add "laptop" --channel work
```

`gw-egress add` generates this gateway's key pair if you do not supply one, and
prints the `[Peer]` block to paste into the exit server. Standing one up is
about fifteen lines: [docs/EXIT-SERVER.md](docs/EXIT-SERVER.md).

Full prerequisites — kernel versions, CGNAT, containers, what each installer
step does: [docs/INSTALL.md](docs/INSTALL.md).

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

Kernel versions, the CGNAT case, containers, and what each installer step does:
[docs/INSTALL.md](docs/INSTALL.md).

## Configuring it by hand

`setup.sh` is a front end for one file. To skip it, start from
`gateway.conf.example` — it documents every setting — and run the installer
yourself:

```bash
cp gateway.conf.example gateway.conf
$EDITOR gateway.conf
sudo ./install.sh --check-only    # validate without changing anything
sudo ./install.sh
```

The installer validates the whole config before touching anything: duplicate
ports, overlapping subnets, channels pointing at egress paths that do not
exist. Re-running it is the normal way to apply a change — it never rotates
keys and never drops clients.

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

## Continuous integration

The `tests` badge is the harness in [test/](test), not a smoke test: every push
installs the whole stack — routing, firewall, ipsets, DNS chain, client
lifecycle — into a privileged container for three different configurations,
installs a second time to assert nothing drifted, and checks that an invalid
config is rejected and rolled back. Every script is shellcheck-clean at
`-S warning` in the same run.

Two `gw-doctor` failures are expected and are filtered out by name: the
placeholder hostname does not resolve, and fixture endpoints are RFC 5737
documentation addresses that never answer. Any other failure fails the build.

What it does not prove: that AmneziaWG's obfuscation works, or that a handshake
completes against a real peer. A container has no kernel WireGuard and no
AmneziaWG module, so those are shimmed — see [test/README.md](test/README.md).

## Contributing

Changes are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the house
rules, and [test/README.md](test/README.md) for the container harness that
installs the whole stack and checks it in about two minutes.

Security reports go to a [security advisory](../../security/advisories/new),
not a public issue. [SECURITY.md](SECURITY.md) covers what is worth knowing
before you run this.

## License

MIT — see [LICENSE](LICENSE).
