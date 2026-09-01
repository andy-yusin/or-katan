# Contributing

## Before you send a change

```bash
shellcheck -S warning install.sh uninstall.sh files/*    # must be clean
test/run.sh                                              # example config
test/run.sh multi-channel                                # the wider config
```

`test/run.sh` needs Docker and about two minutes. See [test/README.md](test/README.md)
for what it actually proves — and for the two FAILs that are expected.

CI runs exactly this on every push and pull request: shellcheck, plus all three
fixtures in parallel. If it passes locally it will pass there, so there is no
value in pushing to find out.

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

Re-running is also how every settings change is applied, so it must be cheap.
An interface is restarted only when its own rendered config actually changed;
anything that restarts unconditionally disconnects every client on the gateway
each time someone edits an unrelated key.

**Failures fail closed.** A dead tunnel egress must leave its routing table
with no default route, so traffic assigned to it stops, rather than quietly
falling back to the box's own uplink. Anything that could turn an outage into
a silent leak is a bug, however convenient it is.

**`gw-doctor` should be able to see it.** If you add a moving part, add the
check that tells someone it is broken. The whole point is that the person
running this can diagnose it without reading the source.

**It has to be legible to a language model, not just to you.** People will
point an assistant at this repo and ask it to add a channel, debug a leak, or
explain why their traffic is going the wrong way. A model that has to guess
will guess confidently and wrongly, and someone's gateway will be misconfigured
because of it. So:

- **Say why, next to the thing.** A model reading `ip rule add ... priority 10`
  cannot recover the reason that number is 10. The comment above it is the only
  place that information exists.
- **Name the invariant when you rely on it.** "Rules are appended in
  `POLICY_RULES` order so the last match wins" is load-bearing; anything that
  reorders them breaks the design silently. Write it down where it is relied on.
- **Keep [AGENTS.md](AGENTS.md) true.** It is the map an assistant reads first.
  If you move a file, add a tool, or change what a config key means, update it
  in the same commit — a stale map is worse than none.
- **Document failure modes, not just usage.** What breaks, what it looks like
  when it breaks, and what to check. [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
  is more valuable to an assistant than the reference sections, because it maps
  symptoms to causes and that is what people actually ask about.
- **Prefer explicit over clever.** An obvious twenty lines beat a dense five.
  Both a newcomer and a model read this the same way: linearly, without the
  context you have in your head right now.

## Style

Bash, `set -euo pipefail`, shellcheck-clean at `-S warning`.

Watch the `set -e` trap: a function whose *last* statement is `a && b` returns
non-zero when `a` fails, which aborts the caller. End such functions with an
explicit `return 0`.

Comments explain why, not what. Assume the reader knows what `ip rule add`
does and does not know why this particular rule sits at priority 10.
