# Contributing

## Before you send a change

```bash
shellcheck -S warning install.sh uninstall.sh files/*    # must be clean
test/run.sh                                              # example config
test/run.sh multi-channel                                # the wider config
```

`test/run.sh` needs Docker and about two minutes. See [test/README.md](test/README.md)
for what it actually proves — and for the one FAIL that is expected.

## What this project tries to be

A gateway you can hand to someone who is not you, and have them run it without
asking you questions. That shapes the rules below more than anything else.

**Nothing is hardcoded that a second person would need to change.** Names,
subnets, ports, protocols, exits and destination policy all come from
`gateway.conf`. If you find yourself typing a specific domain, address or
country into a script, it belongs in the config, or in the docs as an example.

**The installer is safe to re-run, always.** It validates the whole config
before it touches anything, it never rotates a key, and it never drops a
client. If your change can make a second run behave differently from the
first, it is not finished — the idempotency check at the end of `test/run.sh`
exists to catch exactly that.

**Failures fail closed.** A dead tunnel egress must leave its routing table
with no default route, so traffic assigned to it stops, rather than quietly
falling back to the box's own uplink. Anything that could turn an outage into
a silent leak is a bug, however convenient it is.

**`gw-doctor` should be able to see it.** If you add a moving part, add the
check that tells someone it is broken. The whole point is that the person
running this can diagnose it without reading the source.

## Style

Bash, `set -euo pipefail`, shellcheck-clean at `-S warning`.

Watch the `set -e` trap: a function whose *last* statement is `a && b` returns
non-zero when `a` fails, which aborts the caller. End such functions with an
explicit `return 0`.

Comments explain why, not what. Assume the reader knows what `ip rule add`
does and does not know why this particular rule sits at priority 10.
