# Installing

Everything you need before running the installer, and what to expect while it
runs.

## Prerequisites

### The machine

| | |
|---|---|
| **OS** | Ubuntu 24.04 LTS or 22.04 LTS, or Debian 12. Anything with `apt-get` and systemd will probably work; those three are what the installer is tested against. |
| **Architecture** | x86-64 or arm64. |
| **Kernel** | 5.6 or newer, for in-kernel WireGuard. `uname -r` — Ubuntu 22.04+ and Debian 12 are all well past this. |
| **Privileges** | root, via `sudo`. The installer writes to `/etc`, loads kernel modules and changes routing. |
| **CPU / RAM** | 1 core and 512 MB run a household fine. WireGuard is cheap; AdGuardHome is the heaviest thing here and wants ~200 MB. |
| **Disk** | 2 GB free. Most of it is the DNS query log, which rotates. |
| **Network** | A static or reserved address on its LAN, and a way for clients on the internet to reach one UDP port per channel. |

A container works only if it can create network interfaces and load modules —
LXC with `lxc.cap.drop` cleared, or a privileged Docker container. Unprivileged
containers cannot run this. A VM is simpler.

### Kernel modules

The installer checks for these and tells you if they are missing:

- `wireguard` — in-tree since 5.6, so already present on any supported release.
- `amneziawg` — only if you use `awg` channels. It is a DKMS module, so the box
  needs `linux-headers-$(uname -r)` and will rebuild the module on kernel
  upgrades. If headers are unavailable for your kernel, use `wg` channels.

### Reachability

Clients dial in over UDP. **One port per ingress channel** must reach the box:

- **VPS / cloud** — open the ports in the provider's security group or firewall.
- **Home / behind NAT** — forward each UDP port on the router to the gateway's
  LAN address. Give it a DHCP reservation first, or the forward will eventually
  point at nothing.
- **CGNAT** — if your ISP gives you a shared address (your WAN address differs
  from what `curl ifconfig.me` reports, and is inside `100.64.0.0/10`), inbound
  forwarding is not possible. Run the gateway on a VPS instead.

Egress needs no inbound ports. Outbound UDP to your exit servers, and TCP 443
for the DoH resolver, must not be blocked.

### A name, not an address

Strongly preferred. The endpoint is written into every client config that has
ever been issued, so if it is an IP address, changing hosts means re-issuing
every config by hand. With a name you change one DNS record.

Any provider works. An A record pointing at the gateway's public address is all
that is needed — no web server, no certificate, nothing listening on 80 or 443.

### If you want a tunnel egress

You need an exit server before the gateway can use one: a plain WireGuard peer
on a VPS somewhere, or a commercial provider's `.conf` file. Standing one up is
about fifteen lines — see [EXIT-SERVER.md](EXIT-SERVER.md).

You can skip this entirely and install single-hop, with everything leaving via
the gateway's own uplink. Add exits later with `gw-egress add`; nothing has to
be reinstalled and no client is disturbed.

## Installing

```bash
git clone https://github.com/andy-yusin/or-katan.git
cd or-katan
sudo ./setup.sh
```

`setup.sh` asks what you want and writes `gateway.conf`, then offers to install.
Every question has a default, and nothing is written until the end.

It will ask for:

1. **The hostname or address clients dial.**
2. **A policy profile** — a ready-made destination policy. `none` is a fine
   answer; you can apply one later with `gw-config profile <name>`. See
   [../profiles/README.md](../profiles/README.md).
3. **Egress paths** — skip for single-hop, or give it an exit server.
4. **Ingress channels** — the names of the groups that will connect. Ports and
   subnets are assigned for you.
5. **Whether to run the filtering resolver.**

To write the config by hand instead:

```bash
cp gateway.conf.example gateway.conf
$EDITOR gateway.conf
sudo ./install.sh
```

`gateway.conf.example` documents every setting. To check it without changing
anything: `sudo ./install.sh --check-only`.

## What the installer does

In order, stopping at the first problem:

1. **Preflight** — root, distribution, and a readable config.
2. **Validate** — the whole config, before touching anything: name syntax,
   duplicate ports, overlapping subnets, channels pointing at egress paths that
   do not exist, policy rules pointing at nothing. Nothing is written if this
   fails.
3. **Packages** — `wireguard`, `wireguard-tools`, `iptables`, `ipset`,
   `qrencode`, `dnsutils`, and `dnsmasq` + `dnscrypt-proxy` if the DNS stack is
   enabled. AmneziaWG from its own repository, only if an `awg` channel or
   egress is declared.
4. **Kernel tuning** — IPv4 forwarding, reverse-path filtering set to loose
   (policy routing needs it), and IPv6 hardening if you asked for it.
5. **Layout** — `/etc/gateway/` with the config, a copy of the kit, and the
   `gw-*` tools in `/usr/local/bin`. If the installed config and the one in the
   clone differ, the more recently edited one wins — the tools write the
   installed copy, so an old checkout cannot silently revert them.
6. **Keys** — generated in `/etc/gateway/keys/` if absent. **Never rotated**, so
   re-running the installer never invalidates an issued client config.
7. **Egress paths** — one interface per tunnel, with `Table = off` so wg-quick
   installs no route of its own; `gw-routes.sh` owns routing.
8. **Ingress channels** — one interface per channel. Existing `[Peer]` blocks
   are preserved, so clients survive. Each rendered config is compared against
   the previous one; only what actually changed is backed up (three kept — they
   hold private keys) and restarted.
9. **DNS chain** — dnsmasq, dnscrypt-proxy, and AdGuardHome if enabled. The
   AdGuardHome download is checksum-verified.
10. **Services** — systemd units, ordering drop-ins so upstreams come up before
    the channels that depend on them, and the guard against
    `systemd-networkd` flushing policy rules. An interface whose config did not
    change is not restarted: its routing is re-staged with `gw-routes.sh up`
    instead, which disconnects nobody. Turning `DNS_FILTER_ENABLE` off also
    stops and disables AdGuardHome here, before dnsmasq is asked to bind the
    addresses it was holding.
11. **Verification** — runs `gw-doctor`.

It is safe to re-run at any time, and re-running is the normal way to apply a
change.

## After it finishes

```bash
gw-doctor                                # check every layer
gw-client add "moms-phone" --channel family    # prints a QR to scan
gw-egress                                # where is everyone going out?
```

The installer prints the UDP ports to forward. Do that before testing from
outside.

### First client

`gw-client add` writes a config to `/etc/gateway/clients/` and prints a QR code.
Scan it with the **WireGuard** app for a `wg` channel, or the **AmneziaWG** app
for an `awg` channel — a `wg` client cannot read an `awg` config.

### Verifying it actually works

From a connected client:

```bash
curl -s https://api.ipify.org       # should be the egress address, not yours
```

And on the gateway:

```bash
gw-egress test        # proves where each channel's traffic actually exits
gw-client list        # last handshake per client
```

`gw-egress test` is the one that matters. It asks the kernel where a packet
from each channel would actually go, so it catches a leak that a working
internet connection would otherwise hide.

## Upgrading

```bash
cd or-katan && git pull
sudo ./install.sh
```

Keys, clients and your config survive. `gw-config`, `gw-egress` and applied
profiles all write `/etc/gateway/gateway.conf`, not the copy in the clone, so
the installer takes whichever of the two was edited last and says which one it
used. To keep them in sync, copy the installed one back over the clone's:

```bash
sudo cp /etc/gateway/gateway.conf ./gateway.conf
```

If a release changes the config schema, it says so in its notes.

## Uninstalling

```bash
sudo ./uninstall.sh          # keeps keys and clients, so you can reinstall
sudo ./uninstall.sh --purge  # deletes them; every issued config dies
```

`--purge` also removes the timestamped `*.conf.bak-*` interface backups, which
hold the same private keys as the configs themselves.

## When it goes wrong

[TROUBLESHOOTING.md](TROUBLESHOOTING.md) maps symptoms to causes. Start with
`gw-doctor`: it checks in layers, and the first failure is usually the real one.
