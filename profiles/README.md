# profiles

A profile is a ready-made destination policy — the part of `gateway.conf` that
decides which destinations override a channel's default egress. Picking one
during `./setup.sh`, or applying it later with `gw-config profile <name>`,
splices its rules into your config.

```bash
gw-config profiles              # list what is available
gw-config profile ru            # apply one
gw-config profile ru --dry-run  # see what it would change first
```

Applying a profile replaces the whole `POLICY_*` block. It touches nothing
else: channels, egress paths, keys and clients are left alone.

## What ships

| | |
|---|---|
| `none` | No policy at all. Every channel uses its default egress for everything. |
| `split-home` | Banks, tax portals and work intranets go out your own uplink; everything else takes the tunnel. Domains are placeholders — fill in yours. |
| `dev` | One egress per project VPN, each project's hosts routed to its own. For working against several customer or staging networks at once. |
| `ru` | Russian segment: domestic services on the local uplink, video out a dedicated in-country exit, obfuscated ingress. |

`ru` is the only region-specific profile here, because it is the only one whose
values come from a gateway that actually ran in that segment. A profile full of
plausible-looking guesses would be worse than no profile — you would trust it
and it would be wrong.

## Writing your own

Copy the closest one and edit. The format is a fragment of `gateway.conf`
containing the `POLICY_*` block, plus metadata in comments:

```
# title: Short name shown in listings
# summary: One line, shown next to the title.
# ingress-type: wg | awg      — what new channels should default to
# ingress-mtu: 1420           — and at what MTU
# requires-egress: video      — an egress the rules reference but cannot create
# note: Anything the person applying this needs to know. Repeatable.

POLICY_RULES="..."
POLICY_<rule>_EGRESS="..."
POLICY_<rule>_DOMAINS="..."
POLICY_<rule>_CIDRS="..."
POLICY_<rule>_DNS="..."
```

Drop the file in `/etc/gateway/profiles/` (or here, before installing) and it
appears in `gw-config profiles` automatically. `requires-egress` is checked on
apply: you get a warning and the command to create what is missing, rather than
a policy that silently points at nothing.

Rules are applied **in the order listed in `POLICY_RULES`, last match wins** —
that is how a narrow rule carves an exception out of a broad one. See
[../docs/CHANNELS.md](../docs/CHANNELS.md).
