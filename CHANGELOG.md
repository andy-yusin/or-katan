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

### Added

- **Policy feeds.** A destination-policy rule can subscribe to a published CIDR
  list, refreshed on a systemd timer into a third ipset (`gwpf_<rule>`) that
  matches exactly like the static and dnsmasq-filled ones. For rules that need
  addresses in numbers nobody maintains by hand — a country's allocations, a
  large provider's ranges.

  It fails closed, which is the whole design: sources are tried in order, a
  download shorter than `FEED_MIN` is treated as a failure rather than a shorter
  list, and on any failure the previously loaded list stays in place. An emptied
  set would silently reroute every destination it covered. Private, loopback,
  link-local and multicast ranges are dropped whatever the source says, the swap
  into the live set is atomic, and the last good list is cached on disk so a
  reboot does not leave the set empty until the timer next fires.

  New tool `gw-feeds` (`update` / `restore` / `status`). `gw-doctor` reports the
  set size, how long since the last successful refresh, and whether the timer is
  enabled.

- **Policy exclusions.** Address space a destination-policy rule may never
  claim, however it matched. Addresses are shared: a domain a rule covers,
  fronted by a big CDN, resolves to an anycast address serving thousands of
  unrelated sites, dnsmasq drops that address into the rule's set, and from
  then on every one of those sites takes the rule's egress — on a rule pointing
  at the local uplink, foreign sites leaving through the local address and
  being told so by anyone who geolocates it. Ordering cannot express the fix:
  an exception rule picks one egress for every channel, when what is wanted is
  for the broad rule simply not to claim those addresses.

  A fourth ipset, `gwpx_<rule>`, is carried by each of the rule's three
  marking rules as a negative match (not a `RETURN`, which would end the chain
  and break last-match-wins for anything listed after). An excluded
  destination falls back to its channel default. `gw-feeds` fills it from
  `POLICY_<rule>_EXCLUDE_FEED`, whose sources are unioned rather than tried in
  turn — each operator publishes its own ranges — with a per-source cache so
  one list going dark leaves the others current. `profiles/ru.profile` now
  ships the major CDN and cloud lists on its `local` rule; without them it had
  exactly this leak. `gw-doctor` checks the set and the list's age.

- **Egress failover.** An egress path can name others to carry its traffic when
  it stops working. A timer probes each watched path by fetching a URL bound to
  that path's own interface — so a tunnel that is up and handshaking but not
  carrying packets fails it, which an interface or handshake check cannot see —
  and after `HEALTH_THRESHOLD` consecutive failures moves its traffic to the
  first listed alternative that answers.

  What moves is one route: the default in that path's routing table. The
  channels, policy rules and gateway DNS pointed at it all follow, nothing is
  disconnected, and `gateway.conf` is never rewritten — the config keeps saying
  where traffic is meant to go, and the substitution says where it can go now.
  It survives a reboot, so bring-up restores the working path instead of
  pointing the table back at a dead one, and a check that finds no healthy
  candidate changes nothing rather than moving traffic somewhere that also does
  not work.

  The policy is switch-and-stay: a recovered path is not taken back unless
  `HEALTH_FAILBACK="yes"`, because each flap moves the apparent location of
  every client on that path. New tool `gw-health` (`status` / `check` /
  `switch` / `back`); `gw-doctor` reports any substitution in force and says
  when the original is answering again, and `gw-egress` no longer reads a live
  failover as a leak.

- **Snapshots.** `gw-backup`, on a daily timer, saves what a rebuild cannot
  regenerate and can put it back. Everything else on a gateway is generated
  from `gateway.conf` and the keys, so the archive is split along that line:
  `config/` (`/etc/gateway`, `AdGuardHome.yaml`, the cached feed lists) is the
  only part a restore writes, `derived/` is what the installer rendered last
  time — worth diffing against what it renders now — and `state/` is
  `iptables-save`, `ipset save`, `ip rule` and the routing tables, which are
  worth reading the morning after something changed and meaningless to restore.

  A restore takes its own snapshot before writing, so replacing the running
  keys with older ones is undoable; it merges rather than wipes, so clients
  issued since survive it; and without `--yes` it only prints what it would
  touch. Afterwards `install.sh` rebuilds everything derived.

  The archive holds every private key on the box. It is written 0600 into a
  0700 directory to match `/etc/gateway/keys`, `gw-doctor` checks both modes
  and the age of the newest snapshot, and `uninstall.sh --purge` deletes the
  directory — a purge that left a tarball of every key behind would not be one.

### Changed

- `gw-routes.sh` accepts `ensure`, which re-asserts the global routing state
  without naming a channel. It is how a failover becomes a route, and the
  smallest thing that repairs flushed policy rules.
- Every destination-policy marking rule now carries `! --match-set gwpx_<rule>`.
  On upgrade, `gw-routes.sh` removes the old shape of each rule before
  appending the new one, so nothing is duplicated and nobody is disconnected.
- The gateway's own DNS is now MASQUERADEd out of every declared egress
  interface rather than only the one `DNS_EGRESS` names, so those queries keep
  working while that path is being carried by another.

### Fixed

- **MSS was clamped only on forwarded traffic.** The clamp lived in mangle
  `FORWARD`, which never sees the gateway's own connections — and
  `host_dns_egress` deliberately marks some of those (dnscrypt's DoH on :443,
  the plaintext fallback on :53) onto a tunnel. A socket fixes the MSS it
  advertises at `connect()`, from the route it had then, which is the uplink;
  the mark moves it to a smaller-MTU device afterwards and nothing revisits the
  MSS. The result was a SYN promising the uplink's 1460 on a 1420 path: small
  answers arrived, large ones were dropped, and the query stalled through two
  RTO doublings before dnsmasq's `strict-order` fell through to the next
  server. There is now a matching clamp in mangle `POSTROUTING` on each tunnel
  egress interface, which runs after the final routing decision and so sees the
  device the packet really leaves by. `gw-doctor` checks for it.

### Config

- Added `POLICY_<rule>_FEED` — space-separated http, https or file URLs, tried
  in order.
- Added `POLICY_<rule>_FEED_MIN` — the floor below which a download counts as a
  failure. Default 100.
- Added `POLICY_FEED_SCHEDULE` — any systemd `OnCalendar` expression. Default
  `daily`, with an hour of randomised delay.
- Added `POLICY_<rule>_EXCLUDE_FEED` — space-separated http, https or file
  URLs, all fetched and unioned. Declaring it on any rule installs the feeds
  timer, as `_FEED` does.
- Added `POLICY_<rule>_EXCLUDE_CIDRS` — static ranges the rule may never claim.
- Added `EGRESS_<path>_FAILOVER` — other paths, in preference order, to carry
  this one when it fails. Unset means the path is never moved and never used as
  a substitute. Declaring it on any path is what installs the health timer.
- Added `HEALTH_TARGETS` (default `https://1.1.1.1 https://8.8.8.8`),
  `HEALTH_INTERVAL` (30s), `HEALTH_TIMEOUT` (5s), `HEALTH_THRESHOLD` (2),
  `HEALTH_COOLDOWN` (120s) and `HEALTH_FAILBACK` (`no`).
- Added `BACKUP_SCHEDULE` — any systemd `OnCalendar` expression, or `no` to
  take no snapshots. **Defaults to `daily`**, so an upgrade starts writing
  snapshots to `BACKUP_DIR` without being asked: they contain private keys, and
  0600 in a 0700 directory is all that protects them.
- Added `BACKUP_DIR` (default `/var/backups/gateway`) and `BACKUP_KEEP_DAYS`
  (30).

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
