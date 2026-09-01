# title: Split — home things direct, everything else tunnelled
# summary: Banks, tax portals and work intranets see your own address; the rest takes the tunnel.
# ingress-type: wg
# ingress-mtu: 1420
#
# The default shape for someone whose gateway exists to move general traffic
# abroad, but who does not want every login to arrive from another country.
# Fill in the domains — the ones here are placeholders.

POLICY_RULES="home"

# Banks and government portals treat a login from an unexpected country as
# suspicious. Anything that picks a nearby server gets it wrong when "you" are
# an exit two thousand kilometres away. Send them straight out.
POLICY_home_EGRESS="direct"
POLICY_home_DOMAINS="bank.example tax.gov.example intranet.work.example"
POLICY_home_CIDRS=""
# Your router: it knows your local names and answers while a tunnel is down.
POLICY_home_DNS="192.168.1.1"
