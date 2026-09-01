# test

`run.sh` installs the kit into a throwaway privileged container, brings the
whole stack up, and checks it. It is the fastest way to see whether a change
broke something without pointing a real box at it.

```bash
test/run.sh                       # the shipped example config (single-hop)
test/run.sh multi-channel         # 3 channels, 3 egress paths, isolation
test/run.sh policy-seeds          # per-destination egress with ipset seeds
test/run.sh multi-channel --shell # same, then drop into a shell to poke around
```

It runs the installer, `gw-doctor`, `gw-egress`, issues a client on every
channel, then installs a second time and asserts the rule counts did not move.

## What is real and what is faked

Real: iptables, ipset, policy routing, the `ip rule` / `ip route` tables,
dnsmasq, dnscrypt-proxy, every script in `files/`, and the installer's own
validation. `ip route get <dst> from <client-ip> iif <in-iface>` inside the
container answers exactly what the kernel would answer on a real box, so
routing decisions can be asserted directly.

Faked, because a container cannot provide them:

| | |
|---|---|
| kernel WireGuard | `wireguard-go`, the userspace implementation |
| AmneziaWG DKMS | `shims/awg`, `shims/awg-quick` — strip the obfuscation keys, then use `wg` |
| systemd | `shims/systemctl` — translates unit actions into the commands the units would run |

So the tests prove the routing, firewall, DNS and lifecycle logic. They do not
prove that AmneziaWG's obfuscation itself works, or that a handshake completes
against a real peer.

## Fixtures

Two `gw-doctor` FAILs are expected and are not regressions:

- **`GATEWAY_HOST ... does not resolve`** — the harness sets a placeholder
  hostname, since there is no real gateway to point a name at.
- **`never completed a handshake`** — fixtures point their tunnel egress paths
  at RFC 5737 documentation addresses (`203.0.113.0/24`, `198.51.100.0/24`),
  so the interfaces come up but nothing answers.

Everything else should pass.

Egress keys in a fixture are written as `NAME_PUB` / `NAME_PRIV` placeholders
and replaced with a freshly generated pair at run time, so no key is ever
committed.

## If the container cannot reach the apt mirrors

`Unable to locate package` during install means Docker's DNS is not resolving
on your host. Point it somewhere that works:

```bash
DOCKER_DNS=8.8.8.8 test/run.sh multi-channel
```
