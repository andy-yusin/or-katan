# Security

## Reporting

Open a [security advisory](../../security/advisories/new) rather than a public
issue. There is no SLA on this project — it is maintained in spare time — but
reports are read.

## What this software is, in security terms

It routes traffic and it holds the private keys that let clients in. A mistake
in it can send traffic somewhere you did not intend, or expose who is
connecting. Treat the box it runs on as sensitive: root on the gateway is root
on every client's traffic.

## Things worth knowing before you run it

**Keys.** Server and client private keys live in `/etc/gateway/keys/`, mode
0600, root-owned. They are generated on the box and never leave it. The
installer does not rotate them, so a compromised key stays valid until you
`gw-client remove` it or delete the file.

**Your `gateway.conf` holds egress private keys.** It is gitignored here for
that reason. Do not commit yours, and do not paste it into an issue — redact
every `PRIVKEY` and `PSK` first.

**Obfuscation is not authentication.** AmneziaWG channels resist traffic
fingerprinting; they do not make a leaked client config less useful to whoever
leaked it. Revoke, do not rely on obfuscation.

**The obfuscation signature is generated per install, deliberately.** Copying
another gateway's `Jc`/`S1`/`H1..H4` values would let one fingerprint identify
both gateways. If you clone a config, regenerate them.

**DNS is forced.** Client DNS is DNAT'd to the gateway's own resolver, so a
client cannot pick its own. DoT is rejected. DoH over 443 is not blocked and
remains a per-client bypass — by design, since blocking it breaks too much.

**A leaked client config costs you one channel.** That is the reason channels
exist. Put groups you would revoke separately on separate channels.
