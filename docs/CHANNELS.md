# Designing channels, egress paths and policy

## Ingress channels

One channel per group whose treatment differs. The point is not tidiness — a
channel is the unit of routing, isolation and revocation, so anything you might
want to treat differently later should be its own channel now. Splitting later
means reissuing configs.

```ini
INGRESS_CHANNELS="family friends work"

INGRESS_family_TYPE="awg"          # wg | awg
INGRESS_family_PORT="51820"        # unique per channel
INGRESS_family_NET="10.30.10.0/24" # unique per channel; .1 is the gateway
INGRESS_family_MTU="1340"
INGRESS_family_EGRESS="main"       # default way out
INGRESS_family_ISOLATE="no"        # devices can see each other
INGRESS_family_REACH="work"        # ...and this other channel
```

Names must be lowercase `[a-z0-9_]`, 12 characters or fewer — they become
interface names (`in-family`) and shell variable suffixes.

### Picking a type

| | `wg` | `awg` |
|---|---|---|
| Speed | fastest | slightly lower |
| Client app | any WireGuard client | AmneziaWG only |
| Blocked by DPI | sometimes, silently | no |

Use `wg` where you control the network (a laptop at home, a work VPN). Use
`awg` for phones that roam onto mobile networks. When in doubt, `awg`: it works
everywhere `wg` does, plus the places `wg` does not.

Give the same person a client on both if their network is unpredictable —
different channels, different ports, and they switch configs when one stops
passing traffic.

### Isolation

`ISOLATE="yes"` is the right default for anyone who is not you. It means
internet only: no seeing other clients, no reaching other channels, no `.gw`
name. Guests, a friend you are sharing with, an IoT device.

`ISOLATE="no"` plus an empty `REACH` means clients on that channel see each
other but no other channel. Add channel names to `REACH` to open specific paths
— `family` reaching `work` so a laptop can hit a machine on the work channel.

`REACH` is one-directional as written, but the `FORWARD` rules are staged from
both sides, so name it on the channel that initiates.

## Egress paths

```ini
EGRESS_PATHS="main backup video direct"
```

Order matters only in that the first entry is the default for any channel that
does not name one. `direct` — the gateway's own uplink — is always available
even if you do not declare it.

A tunnel egress needs an exit server; see [EXIT-SERVER.md](EXIT-SERVER.md).

```ini
EGRESS_video_TYPE="tunnel"
EGRESS_video_PROTO="wg"                 # wg | awg
EGRESS_video_ENDPOINT="198.51.100.7:51820"
EGRESS_video_PUBKEY="<exit server's public key>"
EGRESS_video_PRIVKEY="<this gateway's private key on that peer>"
EGRESS_video_ADDRESS="10.2.0.2/24"
EGRESS_video_PORT="51902"               # unique local listen port
```

If a provider hands you a ready-made config file instead of separate values,
point at it and skip the individual fields:

```ini
EGRESS_video_TYPE="tunnel"
EGRESS_video_CONF_FILE="/root/provider-nl.conf"
EGRESS_video_PORT="51902"
```

The installer copies it and enforces the two things that must hold here:
`Table = off`, so wg-quick does not install a default route of its own, and a
listen port that does not collide with anything else.

Every tunnel needs its own `PORT`. Two WireGuard interfaces cannot share one.

## Destination policy

Policy overrides the channel default for specific destinations, for **all**
channels:

```ini
POLICY_RULES="local video"

POLICY_local_EGRESS="direct"
POLICY_local_DOMAINS="ru su xn--p1ai yandex.com vk.com"
POLICY_local_CIDRS="5.136.0.0/13"
POLICY_local_DNS="77.88.8.8"

POLICY_video_EGRESS="video"
POLICY_video_DOMAINS="kinopoisk.ru rutube.ru"
```

`DOMAINS` are matched as suffixes, so `ru` covers every `.ru` name and
`kinopoisk.ru` covers its subdomains. As each name resolves, dnsmasq puts the
answer in that rule's ipset and the routing follows — no CIDR maintenance, and
CDNs are covered.

### When domains are not enough

`CIDRS` covers destinations that domain matching structurally cannot catch.
The case that forces it: a service whose player pulls video segments from a
shared anti-DDoS CDN, on addresses not reachable under the service's own
hostname. dnsmasq never sees those names resolved, so nothing lands in the
ipset, and the segments take a different egress than the page did.

The symptom is specific and confusing — **the site loads but will not play**.
Everything you can see in a browser works; only the media stalls.

RuTube is the standard example. Its video rides AS51115 (Qrator) and AS201706
(Servicepipe):

```ini
POLICY_video_EGRESS="video"
POLICY_video_DOMAINS="kinopoisk.ru kp.yandex.net rutube.ru strm.yandex.ru strm.yandex.net vh.yandex.ru vh.yandex.net"
POLICY_video_CIDRS="178.248.233.0/24 178.248.234.0/24 178.248.239.0/24 81.161.99.0/24 109.238.90.0/24"
```

Seeds are static and therefore age. Treat them as a supplement to domain
matching, never a replacement. To refresh them:

```bash
whois -h whois.radb.net -- '-i origin AS51115' | grep ^route
```

To find what a stubborn service actually pulls from, watch what is *not*
landing in the set while you use it:

```bash
tcpdump -ni in-family 'tcp port 443' \
  | grep -vf <(ipset list gwpd_video | grep '^[0-9]')
```

The two sets are separate on purpose: `gwp_<rule>` holds your static seeds and
persists, `gwpd_<rule>` is filled by dnsmasq and entries expire. Both feed the
same marking rule.

`POLICY_<rule>_DNS` gives those domains their own resolver, pinned to the local
uplink. Use it when the "right" answer depends on where the query comes from —
a national resolver returning national addresses — and so that these names keep
resolving while a tunnel egress is down.

### Order is the exception mechanism

Rules are applied in the order listed and **the last match wins**. To carve an
exception out of a broad rule, put the narrow one after it:

```ini
POLICY_RULES="local exception"
POLICY_local_EGRESS="direct"
POLICY_local_DOMAINS="ru su"
POLICY_exception_EGRESS="main"
POLICY_exception_DOMAINS="somesite.ru"      # .ru, but hosted abroad
```

Verify an exception took effect:

```bash
ipset test gwpd_exception <ip>
ip route get <ip> from 10.30.10.2 iif in-family mark 0
```

## A worked example

A household gateway in a country that filters, with an exit abroad:

```ini
EGRESS_PATHS="main video direct"
# main  -> a VPS abroad; video -> a host in the streaming service's country

INGRESS_CHANNELS="family friends iot"

# phones and laptops: obfuscated, see each other, out through main
INGRESS_family_TYPE="awg"; INGRESS_family_EGRESS="main"; INGRESS_family_ISOLATE="no"

# people you share with: obfuscated, isolated, out through main
INGRESS_friends_TYPE="awg"; INGRESS_friends_EGRESS="main"; INGRESS_friends_ISOLATE="yes"

# devices you do not trust: plain wg, isolated, straight out
INGRESS_iot_TYPE="wg"; INGRESS_iot_EGRESS="direct"; INGRESS_iot_ISOLATE="yes"

POLICY_RULES="local video"

# national services stay fast and never see a foreign address
POLICY_local_EGRESS="direct"
POLICY_local_DOMAINS="ru su xn--p1ai yandex.com vk.com"
POLICY_local_DNS="77.88.8.8"

# video listed second, so it overrides "local" for these .ru names
POLICY_video_EGRESS="video"
POLICY_video_DOMAINS="kinopoisk.ru rutube.ru vh.yandex.ru strm.yandex.ru"
POLICY_video_CIDRS="178.248.233.0/24 178.248.234.0/24 178.248.239.0/24 81.161.99.0/24 109.238.90.0/24"
```

Everyone gets filtered DNS. Nobody on `friends` can see anything. The IoT
devices cannot reach the family laptops even though they share a gateway. And
when the exit abroad goes down, `gw-egress set all direct` keeps everyone online
while you fix it.
