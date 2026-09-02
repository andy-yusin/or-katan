# Architecture

```
                     ┌──────────────────── gateway ────────────────────┐
  family  ──in-family│  10.30.10.1   ┐                                 │
  friends ─in-friends│  10.30.20.1   ├─▶ mark ─▶ ip rule ─▶ table ──────┼─▶ out-main
  work    ────in-work│  10.30.30.1   ┘                │                │─▶ out-backup
                     │                               │                 │─▶ eth0 (direct)
                     │  AdGuardHome :53              │                 │
                     │       ↓                       │                 │
                     │  dnsmasq :5353 ─── fills the ipsets the         │
                     │       ↓            marking rules match on       │
                     │  dnscrypt-proxy :5354 ──▶ DoH                   │
                     └─────────────────────────────────────────────────┘
```

Ingress channels on the left, egress paths on the right, and one policy layer
choosing between them per packet.

## Routing

Every egress path gets its own routing table and its own fwmark value, both
derived from its position in `EGRESS_PATHS`:

| Egress | Table | Table id | Mark |
|---|---|---|---|
| 1st listed | `gw_<name>` | 201 | `0x1` |
| 2nd listed | `gw_<name>` | 202 | `0x2` |
| 3rd listed | `gw_<name>` | 203 | `0x3` |

plus `gw_local` (199) holding routes to the channel subnets themselves.

Three rule priorities decide everything:

```
pri  10   from <channel net> to <nets it may reach>   lookup gw_local
pri  50   from all fwmark <egress mark>/0xff          lookup gw_<egress>
pri 100   from <channel net>                          lookup gw_<default egress>
```

Lower number wins, so the order reads:

1. **Internal traffic** to something this channel is allowed to reach stays
   internal.
2. **Anything a policy rule marked** goes out the egress that rule names —
   overriding the channel default.
3. **Everything else** takes the channel's default egress.

Because the pri-50 rules are `from all`, one rule per egress covers every
channel *and* the gateway's own traffic, instead of one rule per
channel × egress.

`ip rule add` does not replace — it prepends another rule at the same priority
and the older one keeps winning. So `setup_channel` deletes this channel's
existing pri-10 and pri-100 rules before adding the current ones. Without that,
changing a channel's egress writes the config, reports success, and changes
nothing.

## Destination policy

A rule is a set of domains, a set of CIDRs, and the egress they should take:

```ini
POLICY_RULES="home stream"
POLICY_home_EGRESS="direct"
POLICY_home_DOMAINS="bank.example tax.gov.example"
POLICY_stream_EGRESS="uk"
POLICY_stream_DOMAINS="stream.example streamcdn.example"
```

Each rule gets three ipsets, and a destination matching any of them takes the
rule's egress:

| set | filled by | scale |
|---|---|---|
| `gwp_<rule>` | `POLICY_<rule>_CIDRS`, rebuilt from config on every bring-up | a handful |
| `gwpd_<rule>` | dnsmasq, as the rule's domains resolve | hundreds |
| `gwpf_<rule>` | `gw-feeds`, from `POLICY_<rule>_FEED` on a timer | tens of thousands |

```
ipset=/bank.example/tax.gov.example/gwpd_home
```

The marking rules live in `mangle PREROUTING`, **appended in the order the
rules are listed**, so a later `--set-mark` overwrites an earlier one: last
match wins. That is what lets a narrow rule carve an exception out of a broad
one — `.ru` out `direct`, but one specific `.ru` domain hosted abroad back onto
the tunnel.

Static CIDR lists go stale and never cover a CDN, which is why domain matching
is the primary mechanism. `gwpd_` starts empty after a reboot and fills as names
resolve; resolution always precedes traffic, so this heals itself.

### Feeds

Domain matching cannot help with a destination reached by address before any
name is looked up, and some rules need those in numbers nobody maintains by
hand — a country's allocations, a large provider's ranges. `POLICY_<rule>_FEED`
points at published lists; `gw-feeds` fetches them on a timer into `gwpf_<rule>`.

Everything about that path is built so a bad fetch cannot change routing:

- Sources are tried in order, and a download shorter than `FEED_MIN` counts as a
  failure rather than as a shorter list — that is what catches a 404 page, a
  truncated transfer, or a source that has quietly emptied.
- If every source fails, **the previously loaded list stays**. An emptied set
  does not fail closed, it fails silently: every destination the rule covered
  starts taking the channel default instead. On a rule pointing at the local
  uplink that means domestic traffic quietly leaving through a foreign exit.
- Private, loopback, link-local and multicast prefixes are dropped whatever the
  source says. A feed containing `0.0.0.0/0` would otherwise blackhole the
  gateway into one egress.
- The swap into the live set is atomic, so a gateway carrying traffic never sees
  a window where the rule stops matching.
- The last good list is cached under `/var/lib/gateway/feeds/`, and reloaded on
  bring-up — ipsets are kernel state, so without that a reboot would leave the
  set empty until the timer next fired.

`gw-doctor` reports the set size, how long since the last successful refresh,
and whether the timer is enabled. A feed that has stopped refreshing is the
quiet failure worth watching for: nothing breaks, the list just ages.

## Isolation

Per channel:

- `ISOLATE=yes` — no pri-10 rule at all, plus explicit `DROP`s. Clients cannot
  see each other or any other channel. Internet only.
- `ISOLATE=no` — clients see each other, and see the channels named in `REACH`.
  Everything else is dropped.

Enforced in both routing (the pri-10 rule is scoped to exactly the reachable
nets) and `FORWARD`. Two independent mechanisms, because a mistake here is
invisible until it matters.

## Failing closed

If a tunnel egress is down when the interfaces come up, its table is left
without a default route. Traffic assigned to it **drops** rather than falling
back to the local uplink.

That is deliberate. Silently leaving from the gateway's own address looks
identical from the client's side while doing the one thing a tunnel egress
exists to avoid. An outage is recoverable and visible; a leak is neither.
`gw-doctor` and `gw-egress test` both report it, and `gw-egress set <channel>
direct` is the deliberate fallback.

## Marks and the gateway's own traffic

The gateway resolves DNS on behalf of every client. Those queries are generated
locally, so they never traverse `PREROUTING` and no channel rule sees them.
Unmarked, they would leave via the local uplink — meaning the network this box
sits on could see exactly what every client looks up, even though client traffic
is tunnelled.

`DNS_EGRESS` names the path they should take. `mangle OUTPUT` marks
dnscrypt-proxy's DoH by uid, and the plaintext fallback resolvers by
destination (which also covers the host's own libc lookups). The pri-50 rule
then routes them like anything else carrying that mark.

## The DNS chain

```
client :53 ──(redirect)──▶ AdGuardHome ──▶ dnsmasq :5353 ──▶ dnscrypt-proxy :5354 ──▶ DoH
```

Three stages, each doing something the others cannot:

- **AdGuardHome** — filtering, per-client stats, a UI, rules changed once for
  every device.
- **dnsmasq** — fills the policy ipsets as names resolve, and serves the
  `<client>.gw` names. `strict-order` is essential: without it dnsmasq races its
  upstreams and the plaintext fallback regularly beats the encrypted one.
- **dnscrypt-proxy** — the encrypted upstream, DoH over TCP/443.

Clients cannot escape it. Port 53 is redirected to the channel's gateway address
whatever the client configured, and DoT (853) is rejected in `FORWARD`. DoH on
443 is deliberately left alone: it is indistinguishable from ordinary HTTPS, and
blocking it would mean breaking HTTPS.

Two fallbacks, neither putting plaintext DNS on the local network:

1. dnscrypt-proxy unreachable → dnsmasq's plain resolver, marked and routed out
   `DNS_EGRESS`.
2. the whole dnsmasq chain unreachable → AdGuardHome's own DoH fallback,
   direct. Encrypted, so only SNI is visible, and it survives an exit outage.

With `DNS_FILTER_ENABLE="no"`, dnsmasq binds the channel gateway addresses on
:53 itself — something has to answer there, since every client query is
redirected to it. Applying that change also stops and disables AdGuardHome,
which was holding those addresses; both cannot bind them at once.

### Serving the uplink side

Everything above applies to tunnelled clients, whose queries are redirected
because they arrive on a channel interface. A router on the same LAN as the
gateway has no tunnel, so nothing redirects it — and the resolver binds only
loopback and the channel gateway addresses, which the LAN cannot reach.

`DNS_LAN_CLIENTS` lists the source ranges allowed to close that gap. What it
installs depends on which resolver is answering, because the two behave
differently:

- **AdGuardHome** binds addresses and nothing else, so the query is redirected:
  its destination is rewritten to a channel gateway address the filter already
  answers on. `AdGuardHome.yaml` is untouched — the installer stops owning that
  file once it exists, so a bind-address setting would silently do nothing on
  every box that already had AdGuard, which is every box that matters.
- **dnsmasq** (`DNS_FILTER_ENABLE="no"`) uses `bind-dynamic`, which device-binds
  each listener. A packet arriving on the uplink never reaches a socket bound to
  a channel interface, whatever its destination says, so redirecting it would
  black-hole it. There the installer gives dnsmasq the uplink interface and the
  query is left alone.

Either way the same pair of firewall rules scopes it: the listed sources are
accepted on :53 from the uplink and everything else on :53 from the uplink is
dropped, rather than left to the INPUT policy. That matters most in the dnsmasq
shape, where a resolver really is bound to the uplink address — the drop is what
keeps it from being an open resolver for whatever the uplink is attached to.
`install.sh` refuses `0.0.0.0/0` outright and warns on anything outside private
space.

The rules live in their own `GW_LAN_DNS` chain, so emptying the setting
converges to no rules without needing to know the previous value.

### Choosing DoH resolvers

By measurement, not reputation. These queries leave via `DNS_EGRESS`, so a
resolver 5 ms from you may be hundreds of ms from that exit — and every uncached
lookup for every client pays it. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Files

| Path | What |
|---|---|
| `/etc/gateway/gateway.conf` | the configuration every tool reads at runtime |
| `/etc/gateway/gw-routes.sh` | routing/NAT/firewall, run from PostUp |
| `/etc/gateway/gw-lib.sh` | the config writer, sourced by `gw-config` and `gw-egress` |
| `/etc/gateway/keys/` | gateway private keys — never rotated by the installer |
| `/etc/gateway/awg-params.conf` | this gateway's obfuscation signature |
| `/etc/gateway/clients/` | issued client configs and QR images |
| `/etc/wireguard/in-<channel>.conf` | a `wg` channel's interface + client list |
| `/etc/amnezia/amneziawg/in-<channel>.conf` | an `awg` channel's interface + client list |
| `/etc/wireguard/out-<egress>.conf` | a tunnel egress |
| `*.conf.bak-<timestamp>` | the previous interface config, kept only when one actually changed; the last three survive. Private keys — treat them as live |

`gw-routes.sh` is idempotent and safe to run by hand — it is the recovery path
whenever routing state is flushed:

```bash
/etc/gateway/gw-routes.sh up family
```
