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

Each rule gets two ipsets: `gwp_<rule>` for the static CIDRs, and
`gwpd_<rule>` which dnsmasq fills as names resolve:

```
ipset=/bank.example/tax.gov.example/gwpd_home
```

The marking rules live in `mangle PREROUTING`, **appended in the order the
rules are listed**, so a later `--set-mark` overwrites an earlier one: last
match wins. That is what lets a narrow rule carve an exception out of a broad
one — `.ru` out `direct`, but one specific `.ru` domain hosted abroad back onto
the tunnel.

Static CIDR lists go stale and never cover a CDN, which is why domain matching
is the primary mechanism. The sets start empty after a reboot and fill as names
resolve; resolution always precedes traffic, so this heals itself.

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
