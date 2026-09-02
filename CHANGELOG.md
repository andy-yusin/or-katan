# Changelog

Notable changes, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the numbering
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

`gateway.conf` is this project's public interface, so every entry that adds,
renames, removes or changes the meaning of a config key says so in its own
**Config** section. Adding a key is a minor release. Renaming or removing one
is a breaking change, and while the version starts with a zero the schema is
still allowed to move — that is what the leading zero is reserving room for.

Upgrading is `git pull && sudo ./install.sh` at any version: the installer
validates the whole config before it touches anything, never rotates a key and
never drops a client. Run `sudo ./install.sh --check-only` first if you want to
see what it makes of your config without changing the box.

## [Unreleased]

## [0.1.0] — 2026-09-01

First tagged release. The kit had been running a real gateway for a while; this
is the point at which it was worth pointing other people at.

### Added

- **Ingress channels.** Named groups of people and devices, one interface each,
  WireGuard or AmneziaWG. Each has its own subnet, MTU, default exit, and rules
  about whether its clients can see each other or reach another channel.
- **Egress paths.** Named ways out — the box's own uplink, or tunnels to exit
  servers. A channel's exit can be switched while it is running, without
  disconnecting anyone.
- **Destination policy.** Per-rule overrides of a channel's exit, matched on
  domains as well as CIDRs. dnsmasq fills the ipsets as names resolve, so there
  is no address list to maintain. Rules apply in `POLICY_RULES` order and the
  last match wins, which is how a narrow exception overrides a broad rule.
- **A DNS chain clients cannot opt out of.** AdGuardHome for filtering, dnsmasq
  for the policy ipsets and the local `<client>.gw` names, dnscrypt-proxy for
  DoH upstream. Port 53 is redirected to the gateway whatever the client
  configured, and DoT is rejected. The gateway's own queries can be routed out
  an exit, so the network it sits on cannot see what clients look up.
- **`DNS_LAN_CLIENTS`** — DNS for machines on the uplink side that never connect
  to a channel. Point a router's DNS at the gateway and the whole house is
  filtered without installing anything on it.
- **Two ingress protocols on purpose.** AmneziaWG for paths that fingerprint and
  drop plain WireGuard, with an obfuscation signature generated per gateway
  rather than copied from another install.
- **Tools.** `gw-client` (issue, list, show, rename, remove, QR codes), `gw-egress`
  (inspect, switch, add, remove exits), `gw-config` (read and write keys, apply
  profiles, validate), `gw-doctor` (layered health check that names the failure
  and the command that fixes it), `gw-setup` (interactive first run).
- **Policy profiles** in `profiles/` — ready-made destination policies, applied
  with `gw-config profile <name>`.
- **CI** — shellcheck plus three full installs into privileged containers,
  covering routing, firewall, ipsets, the DNS chain, client lifecycle, config
  rollback, and a second install asserting nothing drifted.

### Design rules the code holds to

These are invariants, not aspirations — `test/run.sh` checks the ones that can
be checked, and [AGENTS.md](AGENTS.md) lists them all.

- The installer never rotates a key and never drops a client, so re-running is
  always safe. It is also how every settings change is applied.
- An interface is restarted only when its own rendered config actually changed.
- Failures fail closed: an exit that is down leaves its routing table with no
  default route, so traffic assigned to it stops rather than leaking out the
  uplink.
- The installed config wins over the one in the clone, so `git pull` cannot
  silently revert work done with the tools.

### Config

The whole schema is new. Every key is documented in
[gateway.conf.example](gateway.conf.example), which is the reference.

### Known limits

- IPv4 only. `IPV6_HARDEN="yes"` drops IPv6 rather than routing it.
- Debian 12 and Ubuntu 22.04/24.04 only — the installer assumes `apt` and
  systemd.
- The tests prove routing, firewall, DNS and lifecycle logic. They cannot prove
  that obfuscation defeats any particular DPI, or that a real handshake
  completes over a real network.

[Unreleased]: https://github.com/andy-yusin/or-katan/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/andy-yusin/or-katan/releases/tag/v0.1.0
