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
POLICY_RULES="local exception"
POLICY_exception_EGRESS="main"
POLICY_exception_DOMAINS="somesite.ru"
```

Re-run `./install.sh`, then seed the current address so it takes effect before
the next lookup:

```bash
ipset add gwpd_exception "$(dig +short somesite.ru @127.0.0.1 -p 5353 | head -1)"
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
