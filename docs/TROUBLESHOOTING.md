# Troubleshooting

Start with `gw-doctor`. It checks every layer and names the command to run next.
What follows is the set of failures worth knowing about *before* they happen,
because several of them are silent.

---

## A client connects but nothing loads

```bash
gw-client list
```

If the client shows `never` or a handshake many minutes old, packets are not
arriving at all. If the handshake is recent, the tunnel is fine and the problem
is downstream — skip to the next section.

### No handshake

1. **The port is not reachable.** The commonest first-install problem. Check the
   cloud firewall, and if the gateway is behind a router, that it forwards UDP
   to this host:

   ```bash
   gw-client channels        # the port each channel listens on
   ss -ulnp | grep -E '5182|5183'
   ```

   `gw-doctor` warns when `GATEWAY_HOST` does not resolve to a local address,
   which is exactly the behind-NAT case.

2. **The network is dropping WireGuard.** If a `wg` channel never handshakes on
   mobile data but works on Wi-Fi, that is deep packet inspection: plain
   WireGuard has a recognisable handshake and some carriers drop it. Nothing
   errors — it goes quiet.

   Move that person to an `awg` channel:

   ```bash
   gw-client add "phone-obf" --channel friends   # an awg channel
   ```

   They need the **AmneziaWG** app, not the stock WireGuard app.

3. **Wrong app for the channel.** An `awg` config in the stock WireGuard app
   fails to import or silently never connects — the extra parameters are not
   standard WireGuard. `gw-client add` prints which app the config needs.

### Handshake fine, no traffic

Almost always the egress. Ask the kernel directly:

```bash
gw-egress test
```

- `family  out-main via main` — correct.
- `family  no route` — the policy rules are gone. See below.
- `family  LEAKING: eth0, expected out-main` — traffic is leaving from the
  gateway's own address instead of the exit. Nothing looks broken from the
  client's side, which is what makes it dangerous.

Recovery in both cases:

```bash
/etc/gateway/gw-routes.sh up family
```

Idempotent, and it disconnects nobody.

If the channel's egress is a tunnel that is down, traffic is failing closed by
design — see [When an exit dies](#an-exit-path-went-down).

---

## Routing rules vanish on their own

**Symptom:** it worked, nobody touched it, and now a channel is leaking or dead.
Often noticed days after an unattended-upgrades run.

**Cause:** `systemd-networkd` deletes routing policy rules it did not create
whenever it restarts, and it restarts whenever the `systemd` package is
upgraded. This gateway's rules are "foreign" to it. Interfaces stay up and
clients stay connected, which is why it is silent.

**Guard:** the installer writes
`/etc/systemd/networkd.conf.d/10-keep-foreign-rules.conf` with
`ManageForeignRoutingPolicyRules=no`. Verify it holds:

```bash
systemctl restart systemd-networkd
gw-egress test        # must be unchanged
```

**If it happens anyway:** `gw-routes.sh up <channel>` for each channel. On an
unattended box, consider `gw-doctor` from cron.

---

## Changing a channel's egress appears to do nothing

If you edit `INGRESS_<channel>_EGRESS` by hand and restart the interface, check
with `gw-egress test` rather than trusting the config.

`ip rule add` does not replace — it prepends another rule at the same priority
and the *older* rule keeps winning. `gw-routes.sh` deletes the channel's
existing priority-10 and priority-100 rules before adding the current ones, so
the supported path works:

```bash
gw-egress set family backup
```

If you are debugging by hand, look for duplicates:

```bash
ip rule show | grep '^100:'    # exactly one line per channel
```

---

## A config change says it was rolled back

```
ERROR: the change did not validate — config rolled back, nothing applied
ERROR: the gateway refused the change — config rolled back.
```

Two different points of failure, and the difference matters.

The first means the installer's validation rejected the new value: a duplicate
port, a subnet that is not a `/24`, a channel pointing at an egress path that
does not exist. Nothing was applied and nothing on the box moved.

The second means the value was legal but the apply itself failed part-way — a
service would not start, an interface would not come up. The file has been put
back the way it was, but the *running* state may be half-changed, because the
installer had already got as far as it did. The error above it names the step
that failed. Fix that, then:

```bash
gw-config apply     # re-apply the restored config
gw-doctor           # confirm every layer came back
```

Neither case leaves the config describing a state the gateway never reached,
which is what makes `gw-config get` trustworthy after a failure.

---

## A gw-* tool says gw-lib.sh is missing

```
ERROR: gw-lib.sh not found (expected /etc/gateway/gw-lib.sh) — re-run install.sh
```

`gw-config` and `gw-egress` share their config writer, and it lives in
`/etc/gateway/`. This means the tools in `/usr/local/bin` were updated without
the installer being run — usually by copying them in by hand from a clone.

```bash
cd or-katan && sudo ./install.sh
```

Copying `gw-*` into `/usr/local/bin` yourself is never the supported path; the
installer is what keeps `/etc/gateway/` and the tools on the same version.

---

## Everything is slow, but nothing is broken

Pages take seconds to *start* loading, then load fast. Every check passes.

This is nearly always the DoH resolver choice. Those queries leave via
`DNS_EGRESS`, so a resolver a few milliseconds from you can be hundreds of
milliseconds from that exit — and every uncached lookup for every client pays
it.

Measure both paths:

```bash
# as dnscrypt-proxy sees it (through DNS_EGRESS)
sudo -u _dnscrypt-proxy curl -w '%{time_total}\n' -so /dev/null \
  'https://8.8.8.8/dns-query?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB'
# direct, for comparison
sudo curl -w '%{time_total}\n' -so /dev/null \
  'https://8.8.8.8/dns-query?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB'
```

A resolver that measures well direct and badly through the tunnel is the wrong
resolver for this gateway. Change `DNSCRYPT_RESOLVERS`, then:

```bash
systemctl restart dnscrypt-proxy && gw-doctor
```

`gw-doctor` reports each channel's resolver response time; over ~200 ms deserves
attention.

---

## One site takes the wrong path

A destination-policy problem.

**Should take the tunnel but goes direct** — usually a domain matching a broad
rule but hosted somewhere the rule did not intend. Add a narrower rule *after*
the broad one, since the last match wins:

```ini
POLICY_RULES="home exception"
POLICY_exception_EGRESS="main"
POLICY_exception_DOMAINS="vpn.work.example"
```

Re-run `./install.sh`, then seed the current address so it takes effect before
the next lookup:

```bash
ipset add gwpd_exception "$(dig +short vpn.work.example @127.0.0.1 -p 5353 | head -1)"
ip route get <ip> from 10.30.10.2 iif in-family mark 0     # expect the tunnel
```

**The reverse** — a site that blocks the exit's country and should go direct —
is the same mechanism pointed at `direct`.

The sets are empty after a reboot and fill as names resolve. Resolution
precedes traffic, so this self-heals; it is not a bug.

---

## Nothing came back after a reboot

The interface units are `oneshot`: if one fails at boot it stays failed rather
than retrying.

```bash
systemctl status 'wg-quick@in-*' 'awg-quick@in-*'
journalctl -u wg-quick@in-work -b
```

The usual cause is `gw-routes.sh` running before the network had a default route
(it needs one to build the direct table). Start it by hand:

```bash
systemctl start wg-quick@in-work
gw-doctor
```

If it recurs, add `ExecStartPre=/bin/sleep 5` to that unit's drop-in.

**Test the first reboot deliberately**, while you still have another way into
the box. Do not discover this months later.

---

## An exit path went down

Traffic assigned to it **stops** rather than silently leaving from the gateway's
own address.

```bash
gw-doctor                     # names the dead path
gw-egress set all direct      # deliberate fallback, live, no disconnects
gw-egress set all main        # back when it returns
```

Only the channels using that path are affected; channels on other paths keep
working.

If `EGRESS_<path>_FAILOVER` names somewhere for it to go, this happens without
you: the path is probed every `HEALTH_INTERVAL` seconds and its traffic moves
to the first listed path that answers.

```bash
gw-health                     # what is answering, and what is standing in
journalctl -u gw-health       # when it moved, and why
```

What moved is one route — the default in that path's own table — so the
channels, policy rules and gateway DNS pointed at it all followed, nobody was
disconnected, and `gateway.conf` still says what you meant.

It does not move back on its own. A path that failed once usually flaps, and
each flap changes the apparent location of every client on it, so `gw-doctor`
tells you when the original is answering again and you decide:

```bash
gw-health back main           # return it; gw-health back all for every path
```

Set `HEALTH_FAILBACK="yes"` if you would rather it returned by itself.

**A failover that never fires.** `gw-health.timer` has to be enabled
(`gw-doctor` checks), the failed path needs `EGRESS_<path>_FAILOVER`, and the
candidates have to answer a probe themselves — a check where nothing is healthy
deliberately changes nothing rather than moving traffic somewhere that also
does not work. `gw-health` shows all three at once.

---

## DNS rule changes do not take effect

Editing `AdGuardHome.yaml` and reloading is not enough — `SIGHUP` only rotates
logs. It needs a real restart, which costs clients a ~2 second DNS gap:

```bash
systemctl restart AdGuardHome
```

The same trap applies to dnsmasq: `SIGHUP` re-reads `/etc/hosts` but **not** the
config file. `gw-client` restarts it for this reason. If you edit
`/etc/dnsmasq.conf` by hand, `systemctl restart dnsmasq`.

To allow a domain the blocklist eats, add to `user_rules:` in
`AdGuardHome.yaml`:

```yaml
user_rules:
  - '@@||example.com^'
```

---

## The LAN router forwards DNS here and nothing resolves

The resolver binds loopback and the channel gateway addresses. It does not bind
the uplink address, so a router forwarding to this box's LAN address has nothing
to talk to. Name the ranges allowed to use it:

```bash
gw-config set DNS_LAN_CLIENTS "192.168.1.0/24"
```

Check it landed:

```bash
gw-doctor | grep "LAN DNS"
iptables -S GW_LAN_DNS
```

Two PASS lines, and the second one differs by resolver — with the filter on the
query is redirected to an address AdGuardHome binds, and with it off dnsmasq
holds the uplink address itself. Then from a LAN machine — the answer must come
back, and a known-blocked name must come back as `0.0.0.0`, which proves the
filter is answering rather than something upstream:

```bash
dig @<gateway-lan-ip> example.com +short
dig @<gateway-lan-ip> doubleclick.net +short
```

Still nothing:

- **Queries never arrive.** Many home routers race every resolver they know and
  answer from whichever replies first, so removing their other DNS, DoH and DoT
  entries is what actually forces traffic here. `tcpdump -ni <uplink> port 53`
  says whether anything arrives at all.
- **The range is not the one the router sends from.** The rules match on source,
  and the router's own address may be outside the range you listed. Everything
  on :53 from the uplink that is not listed is dropped, so a near miss looks
  exactly like a dead resolver.
- **`ip route get` shows the LAN range leaving through a tunnel.** The reply has
  to go back the way it came. Route the LAN range direct.

`gw-doctor` reports the rules as present or missing; it cannot test the path
from the LAN, so do the two `dig`s above after any change.

---

## A policy feed stopped updating

The quiet one. Nothing breaks when a feed stops refreshing — the set keeps its
last good contents and the rule goes on matching — so the list simply ages until
someone notices traffic taking the wrong exit.

```bash
gw-feeds status                     # prefixes loaded, and how old
systemctl status gw-feeds.timer     # is it even enabled
journalctl -u gw-feeds -n 40        # what the last run said
gw-feeds update <rule>              # run it now, verbosely
```

What it usually is:

- **The source moved or 404s.** `gw-feeds update` says which URL did not answer.
  List a second source: `POLICY_<rule>_FEED` takes several, tried in order.
- **The download is being rejected as too short.** The message names the count
  and the floor. If the list has genuinely shrunk, lower `POLICY_<rule>_FEED_MIN`
  — but check first that the source has not simply broken, because that floor is
  the only thing standing between a bad response and an emptied set.
- **The fetch cannot reach the source at all.** It goes out whichever egress the
  routing sends it to, so a feed can be a casualty of an exit being down. Check
  `gw-doctor` first; the feed is rarely the actual problem.
- **The timer is not enabled.** `gw-doctor` reports this outright. Re-running
  `install.sh` recreates it — the unit is only written when a rule subscribes to
  a feed, so it will not exist if `POLICY_<rule>_FEED` was never set.

If the set is empty rather than stale, the list has never been fetched
successfully. Check the cache: `/var/lib/gateway/feeds/<rule>.list` is written
only on a successful update, and reloaded on every bring-up.

One failure mode with no error message: `ipset swap` refuses two sets whose
creation parameters differ, so if `gwpf_<rule>` was somehow created with a
different `maxelem` or `hashsize`, every update fails silently at the last step.
`ipset destroy gwpf_<rule>` and re-run `gw-routes.sh up <channel>` to recreate
it with the right spec.

---

## Large transfers stall, small requests are fine

An MTU problem: something on the path is dropping the ICMP messages that
path-MTU discovery needs.

MSS is already clamped (`gw-doctor` checks it). If it persists, lower the
client's MTU — 1280 always works:

```
# in the client config's [Interface]
MTU = 1280
```

`awg` channels default to 1340 because obfuscation adds overhead.

---

## Clients cannot see each other

Check whether that is the configuration:

```bash
gw-client channels        # the ISOLATED column
```

`ISOLATE=yes` means internet only — no other clients, no other channels, no
`.gw` name. That is deliberate. To let two channels talk, set `ISOLATE=no` on
the initiating one and list the other in `REACH`, then re-run `install.sh`.

---

## Recovering a lost client config

```bash
gw-client show "laptop"
```

Private keys are not recoverable from the gateway — it holds only public keys.
If the stored file is gone, revoke and reissue:

```bash
gw-client remove "laptop" && gw-client add "laptop" --channel work
```

---

## Moving the gateway to a new host

If `GATEWAY_HOST` is a DNS name, update the A record and every client follows.
If you issued configs against a bare IP, each has that IP baked in and must be
reissued — which is the reason to use a name from day one.

Carry these across to keep existing clients working:

```
/etc/gateway/keys/                          gateway private keys
/etc/gateway/awg-params.conf                obfuscation signature
/etc/wireguard/in-*.conf                    client lists (wg channels)
/etc/amnezia/amneziawg/in-*.conf            client lists (awg channels)
```

Then run `./install.sh` there — it preserves existing keys and clients.
