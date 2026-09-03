#!/bin/bash
#
# gw-routes.sh — build the routing, NAT and firewall state for every ingress
# channel and egress path declared in gateway.conf.
#
# Invoked from each ingress interface's PostUp/PostDown:
#     /etc/gateway/gw-routes.sh up   <channel>
#     /etc/gateway/gw-routes.sh down <channel>
#
# And, for the state that belongs to no single channel:
#     /etc/gateway/gw-routes.sh ensure
#
# Idempotent and safe to run by hand at any time; it disconnects nobody. That
# makes it the recovery path whenever routing state gets flushed.
#
# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------
# Each egress path gets its own routing table (gw_<name>) and its own fwmark
# value. Each ingress channel gets an interface (in-<name>), a subnet, and a
# default egress.
#
#   pri  10   from <channel net> to <reachable nets>  lookup gw_local
#   pri  50   from all fwmark <egress mark>/0xff      lookup gw_<egress>
#   pri 100   from <channel net>                      lookup gw_<default egress>
#
# Lower priority wins. So: traffic between channels that may see each other
# stays internal; anything a destination-policy rule marked goes out the egress
# that rule names; everything else takes the channel's default egress.
# ---------------------------------------------------------------------------

set -euo pipefail

CONF_FILE="${GATEWAY_CONF:-/etc/gateway/gateway.conf}"

TBL_LOCAL="gw_local"
TBL_LOCAL_ID=199
EGRESS_TABLE_BASE=200
MARK_MASK="0xff"

_ch_for_log=""
log() {
    local prefix="[gw-routes"
    [[ -n "$_ch_for_log" ]] && prefix="${prefix} ${_ch_for_log}"
    echo "${prefix}] $*"
}
die() { log "ERROR: $*"; exit 1; }

[[ -r "$CONF_FILE" ]] || die "config not readable: $CONF_FILE"
# shellcheck disable=SC1090
source "$CONF_FILE"

: "${INGRESS_CHANNELS:=}"
: "${EGRESS_PATHS:=direct}"
: "${POLICY_RULES:=}"
: "${DNS_EGRESS:=}"
: "${DNS_FALLBACK:=}"
: "${DNS_LAN_CLIENTS:=}"
: "${DNS_FILTER_ENABLE:=yes}"
: "${IPV6_HARDEN:=no}"
: "${SSH_PORT:=22}"

# --- Uplink ------------------------------------------------------------------
DEF_GW="$(ip route show default | awk '/default/ {print $3; exit}')"
DEF_IF="$(ip route show default | awk '/default/ {print $5; exit}')"

# --- Config accessors --------------------------------------------------------
# Indirect expansion, so channel names are ordinary shell identifiers.
cfg() { local v="$1"; echo "${!v-}"; }

ch_type()    { cfg "INGRESS_${1}_TYPE"; }
ch_port()    { cfg "INGRESS_${1}_PORT"; }
ch_net()     { cfg "INGRESS_${1}_NET"; }
ch_mtu()     { cfg "INGRESS_${1}_MTU"; }
ch_egress()  { local e; e="$(cfg "INGRESS_${1}_EGRESS")"; [[ -n "$e" ]] || e="$(default_egress)"; echo "$e"; }
ch_isolate() { local v; v="$(cfg "INGRESS_${1}_ISOLATE")"; echo "${v:-no}"; }
ch_reach()   { cfg "INGRESS_${1}_REACH"; }
ch_iface()   { echo "in-$1"; }

# "direct" is always available even if it is not declared in the config.
eg_type() {
    local t; t="$(cfg "EGRESS_${1}_TYPE")"
    [[ -n "$t" ]] || { [[ "$1" == "direct" ]] && t="direct" || t=""; }
    echo "$t"
}
eg_proto()   { local p; p="$(cfg "EGRESS_${1}_PROTO")"; echo "${p:-wg}"; }
eg_iface()   { [[ "$(eg_type "$1")" == "direct" ]] && echo "$DEF_IF" || echo "out-$1"; }
eg_table()   { echo "gw_$1"; }

# --- Failover substitutions --------------------------------------------------
# gw-health may be carrying one egress's traffic on another while its own path
# is down. It owns that state, so ask it rather than reading its files: this is
# the same arrangement as `gw-feeds restore` below, and it keeps the format in
# one place. `gw-health substitutions` only reads — it never calls back in here.
#
# Not installed, or nothing substituted, means every table points where the
# config says. A path that is down then simply has no default route and its
# traffic fails closed, which is the behaviour this script had before failover
# existed. gw-lib.sh carries the same reader for the tools that source it; this
# copy exists so the boot path depends on nothing but the config.
HEALTH_SUBS=""
load_health_subs() {
    HEALTH_SUBS=""
    [[ -x /usr/local/bin/gw-health ]] || return 0
    HEALTH_SUBS="$(/usr/local/bin/gw-health substitutions 2>/dev/null)" || HEALTH_SUBS=""
    return 0
}
# The egress actually carrying <egress> right now — itself, unless substituted.
eg_effective() {
    local s
    s="$(awk -v e="$1" '$1==e {print $2; exit}' <<< "$HEALTH_SUBS")"
    echo "${s:-$1}"
}

pol_egress() { cfg "POLICY_${1}_EGRESS"; }
pol_domains(){ cfg "POLICY_${1}_DOMAINS"; }
pol_cidrs()  { cfg "POLICY_${1}_CIDRS"; }
pol_set()    { echo "gwp_$1"; }      # static CIDR seeds
pol_setd()   { echo "gwpd_$1"; }     # populated live by dnsmasq
pol_setf()   { echo "gwpf_$1"; }     # fetched from POLICY_<rule>_FEED by gw-feeds
pol_setx()   { echo "gwpx_$1"; }     # what the rule may never claim: EXCLUDE_CIDRS + EXCLUDE_FEED
pol_xcidrs() { cfg "POLICY_${1}_EXCLUDE_CIDRS"; }

default_egress() { echo "$EGRESS_PATHS" | awk '{print $1}'; }

# Position in EGRESS_PATHS, 1-based — used for both the table id and the mark.
eg_index() {
    local want="$1" i=0 e
    for e in $EGRESS_PATHS; do
        i=$((i+1))
        [[ "$e" == "$want" ]] && { echo "$i"; return 0; }
    done
    return 1
}
eg_mark()     { local i; i="$(eg_index "$1")" || return 1; printf '0x%x' "$i"; }
eg_table_id() { local i; i="$(eg_index "$1")" || return 1; echo $(( EGRESS_TABLE_BASE + i )); }

# Every interface client traffic can leave through.
egress_ifaces() {
    local e
    for e in $EGRESS_PATHS; do eg_iface "$e"; done
    echo "$DEF_IF"
}

# --- iptables helpers --------------------------------------------------------
# Insert at the top, deleting identical copies first: convergent against
# drifted state, never accumulates duplicates.
ipt_insert_once() {
    local tbl="$1" chain="$2"; shift 2
    while iptables -t "$tbl" -C "$chain" "$@" 2>/dev/null; do iptables -t "$tbl" -D "$chain" "$@"; done
    iptables -t "$tbl" -I "$chain" 1 "$@"
}
# Append at the end, same de-duplication. Use where evaluation order matters.
ipt_append_once() {
    local tbl="$1" chain="$2"; shift 2
    while iptables -t "$tbl" -C "$chain" "$@" 2>/dev/null; do iptables -t "$tbl" -D "$chain" "$@"; done
    iptables -t "$tbl" -A "$chain" "$@"
}
ipt_delete_all() {
    local tbl="$1" chain="$2"; shift 2
    while iptables -t "$tbl" -C "$chain" "$@" 2>/dev/null; do iptables -t "$tbl" -D "$chain" "$@"; done
}

iface_addr() { ip -4 -br addr show dev "$1" 2>/dev/null | awk '{print $3}' | head -n1 | cut -d/ -f1 || true; }
net_gw()     { echo "${1%.0/24}.1"; }

count_other_channels() {
    local leaving="${1:-}" n=0 c
    for c in $INGRESS_CHANNELS; do
        [[ "$c" == "$leaving" ]] && continue
        ip link show dev "$(ch_iface "$c")" &>/dev/null && n=$((n+1)) || true
    done
    echo "$n"
}

# =============================================================================
# LAN clients using this gateway as their resolver
# =============================================================================
# A machine on the uplink side — typically the router, forwarding DNS for a
# whole house — has no tunnel, so nothing redirects its queries the way the
# per-channel rules do, and the resolver is not listening on the uplink address.
#
# Two shapes, because the two resolvers behave differently:
#
#   AdGuardHome binds addresses only, so a query can be redirected to one of the
#   channel gateway addresses it already answers on. Nothing in
#   AdGuardHome.yaml changes — the installer stops owning that file once it
#   exists, so a bind-address setting would silently do nothing on every box
#   that already had AdGuard.
#
#   dnsmasq (DNS_FILTER_ENABLE="no") uses bind-dynamic, which device-binds each
#   listener: a packet arriving on the uplink never reaches a socket bound to a
#   channel address, whatever its destination says. Redirecting it drops it.
#   There install.sh gives dnsmasq the uplink interface and the query is left
#   alone — the ACCEPT/DROP pair below is what scopes it.
#
# The rules live in their own chain so that emptying DNS_LAN_CLIENTS converges
# to "no rules" without having to know what the previous value was.
LAN_DNS_CHAIN="GW_LAN_DNS"

lan_dns() {
    local tbl
    for tbl in nat filter; do
        iptables -t "$tbl" -N "$LAN_DNS_CHAIN" 2>/dev/null || true
        iptables -t "$tbl" -F "$LAN_DNS_CHAIN"
    done
    ipt_insert_once nat    PREROUTING -j "$LAN_DNS_CHAIN"
    ipt_insert_once filter INPUT      -j "$LAN_DNS_CHAIN"

    # Nothing configured: leave the chain empty rather than starting to drop
    # port 53 on a box whose operator never asked us to serve or block it.
    [[ -n "$DNS_LAN_CLIENTS" ]] || { log "LAN DNS: none configured"; return 0; }

    local target="" cidr proto
    if [[ "$DNS_FILTER_ENABLE" != "no" ]]; then
        # Any channel gateway address will do — the filter binds all of them —
        # but it has to be one that is actually assigned, or the rewritten
        # packet gets routed instead of delivered locally. Prefer a channel that
        # is up, falling back to the first configured one so the rules are in
        # place for when it comes up.
        local c
        for c in $INGRESS_CHANNELS; do
            [[ -n "$target" ]] || target="$(net_gw "$(ch_net "$c")")"
            if ip link show dev "$(ch_iface "$c")" &>/dev/null; then
                target="$(net_gw "$(ch_net "$c")")"
                break
            fi
        done
        [[ -n "$target" ]] || { log "WARN: no ingress channel to point LAN DNS at; skipping"; return 0; }
    fi

    for cidr in $DNS_LAN_CLIENTS; do
        for proto in udp tcp; do
            if [[ -n "$target" ]]; then
                iptables -t nat -A "$LAN_DNS_CHAIN" -i "$DEF_IF" -s "$cidr" \
                    -p "$proto" --dport 53 -j DNAT --to-destination "$target"
            fi
            iptables -t filter -A "$LAN_DNS_CHAIN" -i "$DEF_IF" -s "$cidr" \
                -p "$proto" --dport 53 -j ACCEPT
        done
    done
    # Everything else arriving on the uplink for :53 is refused here rather than
    # left to the INPUT policy, so the scope holds even where that policy is
    # ACCEPT. Without it, the dnsmasq shape above would be an open resolver for
    # whatever the uplink is attached to.
    for proto in udp tcp; do
        iptables -t filter -A "$LAN_DNS_CHAIN" -i "$DEF_IF" -p "$proto" --dport 53 -j DROP
    done
    log "LAN DNS: ${DNS_LAN_CLIENTS} on ${DEF_IF}${target:+ -> ${target}:53}"
    return 0
}

lan_dns_teardown() {
    ipt_delete_all nat    PREROUTING -j "$LAN_DNS_CHAIN"
    ipt_delete_all filter INPUT      -j "$LAN_DNS_CHAIN"
    local tbl
    for tbl in nat filter; do
        iptables -t "$tbl" -F "$LAN_DNS_CHAIN" 2>/dev/null || true
        iptables -t "$tbl" -X "$LAN_DNS_CHAIN" 2>/dev/null || true
    done
    return 0
}

# =============================================================================
# Global state — shared by every channel
# =============================================================================
ensure_global() {
    log "ensure_global"
    [[ -n "$DEF_GW" && -n "$DEF_IF" ]] || die "no default route on this host"
    command -v ipset >/dev/null 2>&1 || die "ipset binary missing (apt install ipset)"

    local rt=/etc/iproute2/rt_tables
    grep -q "^${TBL_LOCAL_ID} ${TBL_LOCAL}$" "$rt" 2>/dev/null || echo "${TBL_LOCAL_ID} ${TBL_LOCAL}" >> "$rt"

    # --- One routing table per egress path -----------------------------------
    # The table belongs to the egress the config names; the device it points at
    # is whichever egress is carrying that traffic at this moment. They differ
    # only while gw-health has a substitution in force.
    load_health_subs
    local e eff tbl tid dev
    for e in $EGRESS_PATHS; do
        tbl="$(eg_table "$e")"; tid="$(eg_table_id "$e")"
        grep -q "^${tid} ${tbl}$" "$rt" 2>/dev/null || echo "${tid} ${tbl}" >> "$rt"

        eff="$(eg_effective "$e")"
        if [[ "$eff" != "$e" ]]; then
            if eg_index "$eff" >/dev/null 2>&1; then
                log "egress '${e}' is being carried by '${eff}' (gw-health)"
            else
                log "WARN: gw-health names unknown substitute '${eff}' for '${e}'; ignoring it"
                eff="$e"
            fi
        fi

        if [[ "$(eg_type "$eff")" == "direct" ]]; then
            ip route replace default via "$DEF_GW" dev "$DEF_IF" table "$tbl"
        else
            dev="$(eg_iface "$eff")"
            if ip link show "$dev" &>/dev/null; then
                ip route replace default dev "$dev" table "$tbl"
            else
                # Fail closed. Pointing this table at the local uplink instead
                # would silently egress from the wrong address, which looks
                # identical from the client side — the one outcome worth
                # avoiding more than an outage.
                log "WARN: egress '${e}' (${dev}) is down; ${tbl} left without a default (traffic fails closed)"
            fi
        fi
        # Pinned for the configured path, not the substitute: the pin is what
        # lets the real tunnel handshake its way back up.
        [[ "$(eg_type "$e")" == "direct" ]] || egress_endpoint_pin "$e"

        # pri 50: whatever a policy rule marked goes out that egress.
        ip rule add fwmark "$(eg_mark "$e")/${MARK_MASK}" lookup "$tbl" priority 50 2>/dev/null || true
    done
    stale_endpoint_pin_cleanup

    # --- Destination-policy ipsets ------------------------------------------
    # Created unconditionally so the iptables rules referencing them always
    # resolve; an empty set simply never matches.
    local r s
    for r in $POLICY_RULES; do
        s="$(pol_set "$r")"
        ipset create "$s" hash:net family inet hashsize 1024 maxelem 65536 -exist
        ipset create "$(pol_setd "$r")" hash:net family inet hashsize 1024 maxelem 65536 timeout 86400 -exist
        # Feed sets are bigger by orders of magnitude — a country allocation
        # list runs to tens of thousands of prefixes. This spec must match the
        # one in gw-feeds: `ipset swap` refuses two sets created differently,
        # and the symptom is a feed that appears to run and never updates.
        ipset create "$(pol_setf "$r")" hash:net family inet hashsize 4096 maxelem 262144 -exist
        # Address space the rule may never claim, however it matched. Same spec
        # as the feed set, for the same swap reason; gw-feeds unions the fetched
        # lists with the static ranges below, so both writers agree on contents.
        ipset create "$(pol_setx "$r")" hash:net family inet hashsize 4096 maxelem 262144 -exist
        local cidr
        for cidr in $(pol_cidrs "$r"); do
            ipset add "$s" "$cidr" -exist 2>/dev/null || log "WARN: bad CIDR in POLICY_${r}_CIDRS: $cidr"
        done
        for cidr in $(pol_xcidrs "$r"); do
            ipset add "$(pol_setx "$r")" "$cidr" -exist 2>/dev/null \
                || log "WARN: bad CIDR in POLICY_${r}_EXCLUDE_CIDRS: $cidr"
        done
        # Keep the resolver for these names on the local uplink, so lookups for
        # them still work while a tunnel egress is down.
        local pdns
        for pdns in $(cfg "POLICY_${r}_DNS"); do
            ip route replace "${pdns}/32" via "$DEF_GW" dev "$DEF_IF"
        done
    done

    # ipsets live in the kernel, so a reboot empties them and the nightly timer
    # would not refill them until it next fires. Reload the last good list from
    # disk instead — no network, and a no-op when nothing has been fetched yet.
    [[ -x /usr/local/bin/gw-feeds ]] && /usr/local/bin/gw-feeds restore >/dev/null 2>&1 || true

    # --- MSS clamping --------------------------------------------------------
    # Without it, tunnelled TCP blackholes anywhere PMTU discovery is broken.
    ipt_append_once mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    # FORWARD only sees packets being forwarded, so it misses the box's own
    # connections -- and host_dns_egress deliberately marks some of those into
    # a tunnel. A socket fixes the MSS it advertises at connect(), from the
    # route it had then, which is the uplink; the mark moves it to a
    # smaller-MTU device afterwards and nothing revisits the MSS. The result is
    # a SYN promising 1460 on a 1420 path: small answers arrive, large ones are
    # dropped, and the caller sees a multi-second stall rather than an error.
    # POSTROUTING runs after the final routing decision, so -o names the device
    # the packet actually leaves by.
    local mss_e
    for mss_e in $EGRESS_PATHS; do
        [[ "$(eg_type "$mss_e")" == "direct" ]] && continue
        ipt_append_once mangle POSTROUTING -o "$(eg_iface "$mss_e")" -p tcp \
            --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    done

    host_dns_egress
    lan_dns
    listen_ports_open

    if [[ "$IPV6_HARDEN" == "yes" ]]; then
        # Allow the session you are on before tightening, or this locks you out.
        ip6tables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        ip6tables -I INPUT 1 -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true
        ip6tables -I INPUT 1 -i lo -j ACCEPT 2>/dev/null || true
        ip6tables -P FORWARD DROP 2>/dev/null || true
        ip6tables -P INPUT DROP 2>/dev/null || true
    fi
}

# Additive only — the INPUT policy is never changed, so this cannot lock anyone
# out of a box that was reachable before.
listen_ports_open() {
    local c p
    for c in $INGRESS_CHANNELS; do
        p="$(ch_port "$c")"
        [[ -n "$p" ]] && ipt_insert_once filter INPUT -p udp --dport "$p" -j ACCEPT
    done
    return 0
}

# A tunnel's own endpoint must never be routed into that tunnel, or it
# encapsulates its own handshake and deadlocks.
egress_endpoint_pin() {
    local e="$1" ep
    ep="$(cfg "EGRESS_${e}_ENDPOINT")"
    ep="${ep%%:*}"
    [[ -n "$ep" ]] || return 0
    if [[ ! "$ep" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ep="$(getent ahostsv4 "$ep" | awk '{print $1; exit}' || true)"
        [[ -n "$ep" ]] || { log "WARN: cannot resolve endpoint for egress '${e}'; skipping pin"; return 0; }
    fi
    ip rule add to "$ep" lookup main priority 10 2>/dev/null || true
    ip route replace "${ep}/32" via "$DEF_GW" dev "$DEF_IF"
}

# Endpoint pins for tunnels that are no longer configured. This script is the
# only thing that installs "pri 10 to <ip> lookup main" rules.
stale_endpoint_pin_cleanup() {
    local current="" e ep stale
    for e in $EGRESS_PATHS; do
        ep="$(cfg "EGRESS_${e}_ENDPOINT")"; ep="${ep%%:*}"
        [[ -n "$ep" ]] && current="${current} ${ep}"
    done
    while IFS= read -r stale; do
        [[ -n "$stale" ]] || continue
        [[ " ${current} " == *" ${stale} "* ]] && continue
        log "drift: removing stale endpoint pin for ${stale}"
        ip rule del to "$stale" lookup main priority 10 2>/dev/null || true
        ip route del "${stale}/32" 2>/dev/null || true
    done < <(ip rule show 2>/dev/null \
        | awk '/^10:/ && /lookup main/ && /to / {for(i=1;i<=NF;i++) if($i=="to") print $(i+1)}' \
        | sed 's,/32$,,')
}

# The gateway resolves DNS for every client. Those queries are generated
# locally, so they never pass through PREROUTING and the per-channel rules
# never see them. Unmarked, they would leave via the local uplink — meaning
# the network this box sits on could see exactly what every client looks up,
# even though the clients' own traffic is tunnelled.
host_dns_egress() {
    local e="$DNS_EGRESS" mark dev uid fb
    [[ -n "$e" ]] || e="$(default_egress)"
    eg_index "$e" >/dev/null 2>&1 || { log "WARN: DNS_EGRESS '${e}' is not a declared egress; skipping"; return 0; }
    [[ "$(eg_type "$e")" == "direct" ]] && return 0   # already the default path
    mark="$(eg_mark "$e")"

    # Staged for every egress interface, not just this one's: while gw-health
    # is carrying this path on another, these packets leave through a device
    # that was never named here.
    for dev in $(egress_ifaces | sort -u); do
        ipt_insert_once nat POSTROUTING -o "$dev" -m mark --mark "${mark}/${MARK_MASK}" -j MASQUERADE
    done
    if uid="$(id -u _dnscrypt-proxy 2>/dev/null)"; then
        ipt_insert_once mangle OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 443 \
            -j MARK --set-mark "${mark}/${MARK_MASK}"
    fi
    # Matched by destination, so this also covers the host's own libc lookups,
    # not just dnsmasq's fallback.
    for fb in $DNS_FALLBACK; do
        ipt_insert_once mangle OUTPUT -d "$fb" -p udp --dport 53 -j MARK --set-mark "${mark}/${MARK_MASK}"
        ipt_insert_once mangle OUTPUT -d "$fb" -p tcp --dport 53 -j MARK --set-mark "${mark}/${MARK_MASK}"
    done
    return 0
}

teardown_global() {
    log "teardown_global (last channel is leaving)"
    local e fb
    for e in $EGRESS_PATHS; do
        ip rule del fwmark "$(eg_mark "$e")/${MARK_MASK}" lookup "$(eg_table "$e")" priority 50 2>/dev/null || true
        ip route flush table "$(eg_table "$e")" 2>/dev/null || true
    done
    ip route flush table "$TBL_LOCAL" 2>/dev/null || true
    ipt_delete_all mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    for e in $EGRESS_PATHS; do
        [[ "$(eg_type "$e")" == "direct" ]] && continue
        ipt_delete_all mangle POSTROUTING -o "$(eg_iface "$e")" -p tcp \
            --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    done
    lan_dns_teardown
    for fb in $DNS_FALLBACK; do
        ipt_delete_all mangle OUTPUT -d "$fb" -p udp --dport 53 -j MARK --set-mark "$(eg_mark "$(default_egress)")/${MARK_MASK}"
        ipt_delete_all mangle OUTPUT -d "$fb" -p tcp --dport 53 -j MARK --set-mark "$(eg_mark "$(default_egress)")/${MARK_MASK}"
    done
    return 0
}

# =============================================================================
# The isolation matrix
# =============================================================================
# "family may not reach work" is a fact about a *pair* of channels, not about
# either one of them. Installing it from one channel's setup makes it that
# channel's property, and the next teardown of the other channel deletes it and
# never puts it back — which fails open, silently, on the second install.
#
# So the whole matrix is re-derived from the config every time any channel comes
# up or goes down. It is convergent: the answer does not depend on the order the
# channels were processed in, and a rule can never go missing because some other
# channel was restarted.

# Install one verdict for a direction, removing the opposite one if present.
ipt_pair_verdict() {   # <src-net> <dst-net> <ACCEPT|DROP>
    local s="$1" d="$2" want="$3" other
    if [[ "$want" == "ACCEPT" ]]; then other="DROP"; else other="ACCEPT"; fi
    ipt_delete_all  filter FORWARD -s "$s" -d "$d" -j "$other"
    ipt_insert_once filter FORWARD -s "$s" -d "$d" -j "$want"
}

sync_isolation() {
    local a b anet bnet aif a_iso a_reach want
    for a in $INGRESS_CHANNELS; do
        anet="$(ch_net "$a")"; [[ -n "$anet" ]] || continue
        aif="$(ch_iface "$a")"
        a_iso="$(ch_isolate "$a")"
        a_reach="$(ch_reach "$a")"

        # Between two clients of the same channel.
        if [[ "$a_iso" == "yes" ]]; then
            ipt_delete_all  filter FORWARD -s "$anet" -d "$anet" -i "$aif" -o "$aif" -j ACCEPT
            ipt_insert_once filter FORWARD -s "$anet" -d "$anet" -i "$aif" -o "$aif" -j DROP
        else
            ipt_delete_all  filter FORWARD -s "$anet" -d "$anet" -i "$aif" -o "$aif" -j DROP
            ipt_insert_once filter FORWARD -s "$anet" -d "$anet" -i "$aif" -o "$aif" -j ACCEPT
        fi

        # From this channel to every other one.
        for b in $INGRESS_CHANNELS; do
            [[ "$b" == "$a" ]] && continue
            bnet="$(ch_net "$b")"; [[ -n "$bnet" ]] || continue
            # Allowed only if the source names the destination in its REACH
            # list and neither end is isolated. Marking a channel isolated
            # means nobody reaches it, whatever anyone else's REACH says —
            # otherwise the verdict would depend on which channel came up last.
            if [[ "$a_iso" != "yes" && "$(ch_isolate "$b")" != "yes" \
                  && " ${a_reach} " == *" ${b} "* ]]; then
                want="ACCEPT"
            else
                want="DROP"
            fi
            ipt_pair_verdict "$anet" "$bnet" "$want"
        done
    done
    return 0
}

# =============================================================================
# Per-channel state
# =============================================================================
setup_channel() {
    local ch="$1"
    log "setup_channel"
    local net iface gw egress isolate reach
    net="$(ch_net "$ch")";     [[ -n "$net" ]] || die "channel '${ch}' has no INGRESS_${ch}_NET"
    iface="$(ch_iface "$ch")"
    egress="$(ch_egress "$ch")"
    eg_index "$egress" >/dev/null 2>&1 || die "channel '${ch}' points at undeclared egress '${egress}'"
    isolate="$(ch_isolate "$ch")"
    reach="$(ch_reach "$ch")"
    gw="$(iface_addr "$iface")"
    [[ -n "$gw" ]] || die "no IPv4 address on ${iface}"

    ip route replace "$net" dev "$iface" table "$TBL_LOCAL"

    # --- Destination policy marking -----------------------------------------
    # Appended in the order the rules are listed, so a later rule's --set-mark
    # overwrites an earlier one: last match wins. That is what lets a narrow
    # rule carve an exception out of a broad one.
    local r target
    for r in $POLICY_RULES; do
        target="$(pol_egress "$r")"
        if ! eg_index "$target" >/dev/null 2>&1; then
            log "WARN: policy '${r}' names undeclared egress '${target}'; skipping"
            continue
        fi
        # Every match carries the rule's exclusion set as a negative match. Not
        # a RETURN placed above the rule: that would end the chain for every
        # packet to an excluded address, and a rule listed later could no
        # longer claim it — the last-match-wins ordering would silently break.
        local pmark pset
        pmark="$(eg_mark "$target")/${MARK_MASK}"
        for pset in "$(pol_set "$r")" "$(pol_setd "$r")" "$(pol_setf "$r")"; do
            # The shape from before exclusions existed, if an upgrade left it.
            ipt_delete_all mangle PREROUTING -i "$iface" -m set --match-set "$pset" dst -j MARK --set-mark "$pmark"
            ipt_append_once mangle PREROUTING -i "$iface" \
                -m set --match-set "$pset" dst -m set ! --match-set "$(pol_setx "$r")" dst \
                -j MARK --set-mark "$pmark"
        done
    done

    # --- Reachability -------------------------------------------------------
    # Drop this channel's existing pri-10 and pri-100 rules first. `ip rule add`
    # does not replace: it prepends another rule at the same priority and the
    # older one keeps winning. Without this, changing a channel's egress (or its
    # REACH list) writes the config, appears to succeed, and changes nothing.
    while ip rule show | grep -qE "^10:[[:space:]]+from ${net} "; do
        ip rule del from "$net" priority 10 2>/dev/null || break
    done
    while ip rule show | grep -qE "^100:[[:space:]]+from ${net} "; do
        ip rule del from "$net" priority 100 2>/dev/null || break
    done

    # pri 10 is scoped to exactly what this channel may reach, so isolation is
    # enforced in routing as well as in FORWARD.
    if [[ "$isolate" == "yes" ]]; then
        : # no local rule at all: nothing internal is reachable
    else
        ip rule add from "$net" to "$net" lookup "$TBL_LOCAL" priority 10 2>/dev/null || true
        local peer_ch peer_net
        for peer_ch in $reach; do
            peer_net="$(ch_net "$peer_ch")"
            [[ -n "$peer_net" ]] || { log "WARN: REACH names unknown channel '${peer_ch}'"; continue; }
            # An isolated channel is not reachable however this one asks, so do
            # not lay down a route that FORWARD is only going to drop.
            [[ "$(ch_isolate "$peer_ch")" == "yes" ]] && continue
            ip rule add from "$net" to "$peer_net" lookup "$TBL_LOCAL" priority 10 2>/dev/null || true
        done
    fi

    # --- Default egress -----------------------------------------------------
    ip rule add from "$net" lookup "$(eg_table "$egress")" priority 100 2>/dev/null || true

    # --- FORWARD and NAT out every possible egress ---------------------------
    # Staged for every declared egress, not just the current one: a channel can
    # be switched at runtime, and policy rules can send some destinations out a
    # different path than the channel default.
    local dev
    for dev in $(egress_ifaces | sort -u); do
        ipt_insert_once filter FORWARD -s "$net" -o "$dev" -j ACCEPT
        ipt_insert_once filter FORWARD -i "$dev" -d "$net" -j ACCEPT
        ipt_insert_once nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE
    done

    # --- Internal traffic ----------------------------------------------------
    sync_isolation

    # --- DNS -----------------------------------------------------------------
    ipt_insert_once filter INPUT -s "$net" -p udp --dport 53 -j ACCEPT
    ipt_insert_once filter INPUT -s "$net" -p tcp --dport 53 -j ACCEPT
    # DoT would be an easy way around the gateway's resolver. DoH on 443 is
    # indistinguishable from ordinary HTTPS and is deliberately left alone.
    ipt_insert_once filter FORWARD -s "$net" -p udp --dport 853 -j REJECT
    ipt_insert_once filter FORWARD -s "$net" -p tcp --dport 853 -j REJECT
    # Whatever resolver the client configured, it gets this gateway's.
    ipt_insert_once nat PREROUTING -i "$iface" -p udp --dport 53 ! -d "$gw" -j DNAT --to-destination "$gw"
    ipt_insert_once nat PREROUTING -i "$iface" -p tcp --dport 53 ! -d "$gw" -j DNAT --to-destination "$gw"
}

teardown_channel() {
    local ch="$1"
    log "teardown_channel"
    local net iface gw egress
    net="$(ch_net "$ch")"; [[ -n "$net" ]] || return 0
    iface="$(ch_iface "$ch")"
    egress="$(ch_egress "$ch")"
    gw="$(iface_addr "$iface")"

    while ip rule show | grep -q "from ${net} .*lookup ${TBL_LOCAL}"; do
        ip rule del from "$net" lookup "$TBL_LOCAL" 2>/dev/null || break
    done
    eg_index "$egress" >/dev/null 2>&1 && \
        ip rule del from "$net" lookup "$(eg_table "$egress")" priority 100 2>/dev/null || true

    local dev
    for dev in $(egress_ifaces | sort -u); do
        ipt_delete_all filter FORWARD -s "$net" -o "$dev" -j ACCEPT
        ipt_delete_all filter FORWARD -i "$dev" -d "$net" -j ACCEPT
        ipt_delete_all nat POSTROUTING -s "$net" -o "$dev" -j MASQUERADE
    done
    ipt_delete_all filter INPUT -s "$net" -p udp --dport 53 -j ACCEPT
    ipt_delete_all filter INPUT -s "$net" -p tcp --dport 53 -j ACCEPT
    ipt_delete_all filter FORWARD -s "$net" -p udp --dport 853 -j REJECT
    ipt_delete_all filter FORWARD -s "$net" -p tcp --dport 853 -j REJECT
    ipt_delete_all filter FORWARD -s "$net" -d "$net" -i "$iface" -o "$iface" -j ACCEPT
    ipt_delete_all filter FORWARD -s "$net" -d "$net" -i "$iface" -o "$iface" -j DROP

    # Drop every pair rule that mentions this channel, in both directions and
    # both verdicts — including ones another channel installed. Nothing puts
    # them back here on purpose: while this channel is down its subnet cannot
    # source or receive anything, and the next setup_channel re-derives the
    # whole matrix from the config anyway.
    local other onet
    for other in $INGRESS_CHANNELS; do
        [[ "$other" == "$ch" ]] && continue
        onet="$(ch_net "$other")"; [[ -n "$onet" ]] || continue
        ipt_delete_all filter FORWARD -s "$net" -d "$onet" -j ACCEPT
        ipt_delete_all filter FORWARD -s "$net" -d "$onet" -j DROP
        ipt_delete_all filter FORWARD -s "$onet" -d "$net" -j ACCEPT
        ipt_delete_all filter FORWARD -s "$onet" -d "$net" -j DROP
    done

    local r target
    for r in $POLICY_RULES; do
        target="$(pol_egress "$r")"
        eg_index "$target" >/dev/null 2>&1 || continue
        local pmark pset
        pmark="$(eg_mark "$target")/${MARK_MASK}"
        for pset in "$(pol_set "$r")" "$(pol_setd "$r")" "$(pol_setf "$r")"; do
            ipt_delete_all mangle PREROUTING -i "$iface" -m set --match-set "$pset" dst -j MARK --set-mark "$pmark"
            ipt_delete_all mangle PREROUTING -i "$iface" \
                -m set --match-set "$pset" dst -m set ! --match-set "$(pol_setx "$r")" dst \
                -j MARK --set-mark "$pmark"
        done
    done

    if [[ -n "$gw" ]]; then
        ipt_delete_all nat PREROUTING -i "$iface" -p udp --dport 53 ! -d "$gw" -j DNAT --to-destination "$gw"
        ipt_delete_all nat PREROUTING -i "$iface" -p tcp --dport 53 ! -d "$gw" -j DNAT --to-destination "$gw"
    fi
    return 0
}

usage() { echo "usage: $0 {up|down} <channel>   |   $0 ensure" >&2; exit 1; }

main() {
    local action="${1:-}" ch="${2:-}"
    [[ $EUID -eq 0 ]] || die "must run as root"

    # Global state only: no channel named, nothing brought up or torn down.
    # This is how gw-health turns a failover decision into a route, and it is
    # the smallest thing that repairs flushed policy rules.
    if [[ "$action" == "ensure" ]]; then
        ensure_global
        log "ensure complete"
        return 0
    fi

    [[ -n "$action" && -n "$ch" ]] || usage
    _ch_for_log="$ch"
    [[ " ${INGRESS_CHANNELS} " == *" ${ch} "* ]] || die "'${ch}' is not in INGRESS_CHANNELS"

    case "$action" in
        up)
            ensure_global
            setup_channel "$ch"
            log "up complete (egress: $(ch_egress "$ch"))"
            ;;
        down)
            teardown_channel "$ch"
            if [[ "$(count_other_channels "$ch")" -eq 0 ]]; then
                teardown_global
            else
                log "other channels still up; leaving global state in place"
            fi
            log "down complete"
            ;;
        *) usage ;;
    esac
}

main "$@"
