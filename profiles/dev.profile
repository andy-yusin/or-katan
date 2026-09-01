# title: Development — per-project traffic through per-project exits
# summary: Each project's hosts leave through that project's VPN; everything else goes direct.
# ingress-type: wg
# ingress-mtu: 1420
# requires-egress: project_a
# requires-egress: project_b
# note: Rename the rules and exits to your projects. The point is the shape:
# note: one egress per network you must appear to be inside, and one policy
# note: rule naming the hosts that belong to it.
# note: You do not need a client VPN per laptop — the gateway holds them all,
# note: and every machine behind it picks the right one by destination.
#
# The problem this solves: three customers, three VPNs, and a laptop that can
# only sensibly hold one at a time. Terminate all of them on the gateway
# instead and route by destination, so staging for A and staging for B are
# reachable at the same time, from every machine, without toggling anything.

POLICY_RULES="project_a project_b"

# --- project_a ----------------------------------------------------------------
# Their VPN is the only way into these, and it must be the source address they
# see. CIDRS matters here more than for public services: internal hosts are
# often reached by address, with no name to match on.
POLICY_project_a_EGRESS="project_a"
POLICY_project_a_DOMAINS="internal.project-a.example staging.project-a.example"
POLICY_project_a_CIDRS="10.50.0.0/16"

# --- project_b ----------------------------------------------------------------
POLICY_project_b_EGRESS="project_b"
POLICY_project_b_DOMAINS="internal.project-b.example git.project-b.example"
POLICY_project_b_CIDRS="10.60.0.0/16"

# Anything not named above uses the channel's own default egress, so ordinary
# browsing is unaffected and no project's VPN carries traffic that is not its own.
