# title: Russian segment
# summary: Domestic services stay on the local uplink; video gets its own in-country exit.
# ingress-type: awg
# ingress-mtu: 1340
# requires-egress: video
# note: Plain WireGuard is fingerprinted and dropped by mobile DPI here. Use awg
# note: ingress channels for anything that will be used on cellular.
# note: The 'video' rule needs an egress named 'video' terminating inside the
# note: country. Add one with: gw-egress add video --endpoint <host>:<port> ...
#
# Derived from a gateway that has run in this segment for years. Every value
# below is a published allocation or a public resolver — nothing here is
# specific to one deployment.

POLICY_RULES="local video"

# --- local: domestic services, straight out the uplink ------------------------
# They resolve to domestic addresses and are frequently unreachable, throttled
# or geo-refused from a foreign exit. Sending them direct keeps them fast and
# keeps them working.
POLICY_local_EGRESS="direct"
POLICY_local_DOMAINS="ru su xn--p1ai yandex.ru yandex.com yandex.net vk.com vk.ru mail.ru ok.ru"
# Two large consumer allocations, as a floor under the domain matching for
# hosts that are reached by address before any name is resolved.
POLICY_local_CIDRS="5.136.0.0/13 87.240.0.0/12"
# A domestic resolver, pinned to the uplink: it returns better-located answers
# for domestic CDNs, and these names keep resolving while a tunnel is down.
POLICY_local_DNS="77.88.8.8"
# Address space the rule may never claim, however a name resolved. A domestic
# site fronted by a global CDN resolves to an anycast address shared with
# thousands of foreign sites; without this, every one of them would leave
# through the local uplink — and be told so by anyone geolocating that address.
# The operators' own published lists, unioned. Domestic organisations on
# prefixes the country allocation misses are deliberately not here: that is
# exactly what the rule is for, and a bank behind one refuses a foreign exit.
POLICY_local_EXCLUDE_FEED="https://www.cloudflare.com/ips-v4 https://ip-ranges.amazonaws.com/ip-ranges.json https://www.gstatic.com/ipranges/goog.json https://www.gstatic.com/ipranges/cloud.json"
# Fastly (https://api.fastly.com/public-ip-list) belongs here too, but refuses
# requests from inside the segment. Add it if the gateway's uplink is elsewhere.

# --- video: streaming, out an exit inside the country -------------------------
# Listed after 'local', so it wins for these names even though they are also
# domestic — the last-match-wins mechanism.
POLICY_video_EGRESS="video"
POLICY_video_DOMAINS="kinopoisk.ru kp.yandex.net rutube.ru strm.yandex.ru strm.yandex.net vh.yandex.ru vh.yandex.net"
# Video is fronted through shared anti-DDoS CDN ranges — AS51115 (Qrator) and
# AS201706 (Servicepipe) — on addresses that are not always reachable under a
# name the rule above matches. Without these the page loads and will not play.
# Seeds age: refresh with
#   whois -h whois.radb.net -- '-i origin AS51115' | grep ^route
POLICY_video_CIDRS="178.248.233.0/24 178.248.234.0/24 178.248.239.0/24 81.161.99.0/24 109.238.90.0/24"
