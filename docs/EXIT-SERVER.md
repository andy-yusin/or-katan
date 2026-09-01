# Standing up a tunnel egress

A tunnel egress is a second machine that traffic leaves from. The gateway
forwards to it over WireGuard, so the address the internet sees is the exit's,
and the network the gateway sits on only ever sees encrypted traffic leaving.

```
client ──▶ gateway ──out-main──▶ exit server ──▶ internet
           (channels, DNS,        (an ordinary
            filtering, policy)     WireGuard server)
```

Worth doing when the box you can afford or physically reach is not in the
country you want to appear from, or when you want the entry point and the exit
address to be separable. The cost is a second machine, some latency, and one
more thing that can break — `gw-egress set all direct` is the escape hatch.

No part of or-katan runs on the exit. It is a plain WireGuard server, which
also means a commercial provider's config works just as well; skip to
[Using a provider's config](#using-a-providers-config).

## Your own exit server

On a fresh Debian/Ubuntu box:

```bash
apt update && apt install -y wireguard-tools
umask 077
wg genkey | tee /etc/wireguard/exit.key | wg pubkey > /etc/wireguard/exit.pub
```

Create `/etc/wireguard/wg0.conf` — replace `eth0` with the real uplink from
`ip route show default`:

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <contents of /etc/wireguard/exit.key>
PostUp   = iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
# the gateway
PublicKey = <the gateway's public key — generated in the next step>
AllowedIPs = 10.0.0.2/32
```

```bash
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wg.conf && sysctl --system
systemctl enable --now wg-quick@wg0
```

Open UDP 51820 in its firewall.

### Pointing the gateway at it

On the gateway, generate the keypair it will present:

```bash
umask 077
wg genkey | tee /tmp/egress.key | wg pubkey     # <- the public key
cat /tmp/egress.key                             # <- the private key
```

Put the public key in the exit's `[Peer]` block and reload it there:

```bash
wg syncconf wg0 <(wg-quick strip wg0)
```

Then declare the egress in `gateway.conf`:

```ini
EGRESS_PATHS="main direct"
EGRESS_main_TYPE="tunnel"
EGRESS_main_PROTO="wg"
EGRESS_main_ENDPOINT="<exit IP>:51820"
EGRESS_main_PUBKEY="<exit server's public key>"
EGRESS_main_PRIVKEY="<the private key you just generated>"
EGRESS_main_ADDRESS="10.0.0.2/24"
EGRESS_main_PORT="51900"
```

`EGRESS_main_PORT` is the gateway's *local* listen port for this tunnel. Every
tunnel needs a distinct one, and none may collide with an ingress channel port.

Apply and verify, then delete the staged key:

```bash
sudo ./install.sh
gw-doctor
rm -f /tmp/egress.key
```

`gw-doctor` checks the handshake and — decisively — that a packet from a real
client address resolves to `out-main`.

## Using a provider's config

Commercial WireGuard providers hand you a `.conf`. Point at it instead of
filling in the fields:

```ini
EGRESS_main_TYPE="tunnel"
EGRESS_main_CONF_FILE="/root/provider-nl.conf"
EGRESS_main_PORT="51900"
```

The installer copies it and enforces `Table = off` (so wg-quick does not install
a default route that would hijack the whole box) and the listen port. An
AmneziaWG provider config works the same way with `EGRESS_main_PROTO="awg"` —
the obfuscation parameters come from their file.

Read a provider config before using it. `AllowedIPs = 0.0.0.0/0` is expected
here; a `DNS =` line is ignored, since this gateway runs its own resolver.

## Switching

```bash
gw-egress                       # every path, its health, and who uses it
gw-egress set family backup     # move one channel
gw-egress set all direct        # move everything — the exit went down
gw-egress test                  # prove where each channel actually exits
```

Live: clients stay attached to their ingress interface and only the path
underneath changes. The choice is written to the config and survives a reboot.

> `gw-egress` writes into `/etc/gateway/gateway.conf`. If you keep an edited
> copy in the kit directory, mirror the change back — re-running `install.sh`
> copies the kit's file over the installed one.

## When an exit dies

Traffic assigned to it stops, rather than falling back to the gateway's own
address. That is deliberate: a silent fallback looks identical from the client
side while defeating the point of the tunnel.

```bash
gw-doctor                    # names the dead path
gw-egress set all direct     # deliberate fallback, live
gw-egress set all main       # back again when it returns
```
