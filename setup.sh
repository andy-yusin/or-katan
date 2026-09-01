#!/bin/bash
#
# setup.sh — write a gateway.conf by answering questions.
#
#   ./setup.sh                    ask everything, then offer to install
#   ./setup.sh --host gw.example.com --profile ru --defaults
#                                 take every default, ask nothing
#
# Declare any number of channels and exits without prompting:
#
#   ./setup.sh --host gw.example.com --defaults \
#       --channels "family work lab" \
#       --egress "main,203.0.113.10:51820,<pubkey>,10.0.0.2/24" \
#       --egress "uk,198.51.100.7:51820,<pubkey>,10.2.0.2/24" \
#       --egress "client_a,conf=/root/client-a.conf"
#
# --egress is repeatable. The first one given is the default egress. Its fields
# are name, endpoint, the exit's public key, and this gateway's address inside
# the tunnel; append a fifth for a preshared key, or use conf=<path> for a
# provider-supplied file. A private key is generated if you do not supply one.
#
# Installed as `gw-setup`, so the same wizard is available later to lay down a
# fresh config. It never touches a running gateway on its own: it writes the
# file and asks before handing over to the installer.
#
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "${KIT_DIR}/profiles" ]] || KIT_DIR="/etc/gateway"
PROFILE_DIR="${KIT_DIR}/profiles"
OUT="${GATEWAY_CONF_OUT:-${KIT_DIR}/gateway.conf}"
[[ -w "$(dirname "$OUT")" ]] || OUT="/etc/gateway/gateway.conf"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
die()  { printf '\n%sERROR:%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
step() { printf '\n%s==>%s %s%s%s\n' "$CYAN" "$NC" "$BOLD" "$1" "$NC"; }
note() { printf '    %s%s%s\n' "$DIM" "$1" "$NC"; }
ok()   { printf '    %s✓%s %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$NC" "$1"; }

HOST=""; PROFILE=""; DEFAULTS=no; CHANNELS_ARG=""
declare -a EGRESS_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)     HOST="${2:-}"; shift 2 ;;
        --profile)  PROFILE="${2:-}"; shift 2 ;;
        --channels) CHANNELS_ARG="${2:-}"; shift 2 ;;
        --egress)   EGRESS_ARGS+=("${2:-}"); shift 2 ;;
        --defaults) DEFAULTS=yes; shift ;;
        --out)      OUT="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '2,26p' "$0" | sed 's/^#//;s/^ //'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

# --- prompting ---------------------------------------------------------------
# Every question has a default. In --defaults mode the default is simply taken,
# which is what makes the wizard usable from a script and testable.

# Answers cannot be piped in: every question would take its default while the
# piped text went unread, and the config that came out would look close enough
# to what was asked for to pass unnoticed. Say so instead.
[[ "$DEFAULTS" == yes || -t 0 ]] || die "stdin is not a terminal, so there is nobody to ask.
    Re-run with --defaults to take every default, and pass the answers as options:
    --host <name> --profile <name> --channels \"a b\" --egress \"name,endpoint,pubkey,address\""

ask() {   # <prompt> <default> -> stdout
    local q="$1" d="${2:-}" a=""
    if [[ "$DEFAULTS" == yes ]]; then printf '%s\n' "$d"; return 0; fi
    if [[ -n "$d" ]]; then printf '    %s [%s]: ' "$q" "$d" >&2; else printf '    %s: ' "$q" >&2; fi
    read -r a || true
    printf '%s\n' "${a:-$d}"
}

ask_yn() {   # <prompt> <yes|no> -> yes|no
    local a; a="$(ask "$1 (y/n)" "$2")"
    case "${a,,}" in y|yes) echo yes ;; n|no) echo no ;; *) echo "$2" ;; esac
}

ask_one() {   # <prompt> <default> <valid...> -> one of valid
    local q="$1" d="$2"; shift 2
    local a; a="$(ask "$q" "$d")"
    for v in "$@"; do [[ "$a" == "$v" ]] && { echo "$a"; return 0; }; done
    echo "$d"
}

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_]*$ ]]; }

# =============================================================================
printf '\n%s%sor-katan setup%s\n' "$BOLD" "$CYAN" "$NC"
note "Writing to ${OUT}"
[[ -e "$OUT" ]] && warn "${OUT} exists and will be overwritten (a .bak is kept)"

# =============================================================================
step "This gateway"
# =============================================================================
if [[ -z "$HOST" ]]; then
    guess="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
    note "Clients dial this name. A DNS name beats an address: the name is baked"
    note "into every client config, so you can move the box and clients follow."
    HOST="$(ask "Public hostname or IP" "${guess:-}")"
fi
[[ -n "$HOST" ]] || die "a hostname or address is required (--host)"
ok "clients will connect to ${HOST}"

# =============================================================================
step "Policy profile"
# =============================================================================
# A profile is a ready-made destination policy plus the ingress defaults that
# go with it. It can be changed at any time with `gw-config profile <name>`.
PROF_TYPE="wg"; PROF_MTU_WG="1420"; PROF_MTU_AWG="1340"

profile_meta() { grep -E "^# ${2}:" "$1" 2>/dev/null | sed -E "s|^# ${2}:[[:space:]]*||" || true; }

if [[ -z "$PROFILE" ]] && [[ -d "$PROFILE_DIR" ]]; then
    avail=""
    shopt -s nullglob
    for f in "$PROFILE_DIR"/*.profile; do
        n="$(basename "$f" .profile)"; avail="${avail} ${n}"
        printf '    %-14s %s\n' "$n" "$(profile_meta "$f" title)"
        printf '    %s%-14s %s%s\n' "$DIM" "" "$(profile_meta "$f" summary)" "$NC"
    done
    shopt -u nullglob
    # shellcheck disable=SC2086
    PROFILE="$(ask_one "Profile" "none" $avail)"
fi

PROF_FILE="${PROFILE_DIR}/${PROFILE}.profile"
if [[ -n "$PROFILE" && -r "$PROF_FILE" ]]; then
    t="$(profile_meta "$PROF_FILE" ingress-type)"; [[ -n "$t" ]] && PROF_TYPE="$t"
    m="$(profile_meta "$PROF_FILE" ingress-mtu)"
    # The profile's MTU belongs to the protocol it recommends; the other
    # protocol keeps its own default, so switching does not inherit a wrong one.
    if [[ -n "$m" ]]; then
        [[ "$PROF_TYPE" == "awg" ]] && PROF_MTU_AWG="$m" || PROF_MTU_WG="$m"
    fi
    ok "profile '${PROFILE}' — $(profile_meta "$PROF_FILE" title)"
else
    [[ -n "$PROFILE" ]] && warn "no profile named '${PROFILE}'; continuing with no policy"
    PROFILE=""
fi

# =============================================================================
step "Egress — how traffic leaves"
# =============================================================================
note "'direct' is this box's own uplink and always exists. A tunnel egress"
note "sends traffic on to an exit server you control; see docs/EXIT-SERVER.md."
EG_TUNNELS=""
declare -a EG_BLOCKS=()
eg_port=51900
egress_list() { local l="${EG_TUNNELS# } direct"; echo "${l# }"; }

add_tunnel_egress() {   # [suggested name]
    local name proto endpoint pubkey privkey psk addr conffile
    name="$(ask "  name for this exit (e.g. main, uk, backup)" "${1:-main}")"
    valid_name "$name" || { warn "names are lowercase letters, digits and _; skipping"; return 0; }
    [[ " $(egress_list) " == *" $name "* ]] && { warn "'${name}' already declared; skipping"; return 0; }

    conffile="$(ask "  path to a provider .conf, or blank to enter values" "")"
    if [[ -n "$conffile" ]]; then
        EG_BLOCKS+=("EGRESS_${name}_TYPE=\"tunnel\"
EGRESS_${name}_CONF_FILE=\"${conffile}\"
EGRESS_${name}_PORT=\"${eg_port}\"")
    else
        proto="$(ask_one "  protocol (wg/awg)" "wg" wg awg)"
        endpoint="$(ask "  exit endpoint host:port" "")"
        pubkey="$(ask "  exit server public key" "")"
        privkey="$(ask "  this gateway's private key on that peer (blank: generate one)" "")"
        psk="$(ask "  preshared key, if the exit uses one" "")"
        addr="$(ask "  this gateway's address inside that tunnel" "10.0.0.2/24")"
        # Nobody standing up their first exit has a private key yet — that is
        # why `gw-egress add` makes one. Leaving the field empty here only gets
        # the config rejected by the installer two steps later.
        if [[ -z "$privkey" ]]; then
            local keytool="wg"; [[ "$proto" == "awg" ]] && keytool="awg"
            if command -v "$keytool" >/dev/null; then
                privkey="$($keytool genkey)"
                note "generated a key pair — add this peer on the '${name}' exit:"
                printf '      [Peer]\n      PublicKey = %s\n      AllowedIPs = %s/32\n\n' \
                    "$(printf '%s' "$privkey" | "$keytool" pubkey)" "${addr%%/*}"
            else
                warn "no '${keytool}' on PATH yet, so no key could be generated"
                note "run '${keytool} genkey' after installing and put it in EGRESS_${name}_PRIVKEY,"
                note "or declare this exit later with: gw-egress add ${name} --endpoint ... --pubkey ... --address ..."
            fi
        fi
        EG_BLOCKS+=("EGRESS_${name}_TYPE=\"tunnel\"
EGRESS_${name}_PROTO=\"${proto}\"
EGRESS_${name}_ENDPOINT=\"${endpoint}\"
EGRESS_${name}_PUBKEY=\"${pubkey}\"
EGRESS_${name}_PRIVKEY=\"${privkey}\"
EGRESS_${name}_PSK=\"${psk}\"
EGRESS_${name}_ADDRESS=\"${addr}\"
EGRESS_${name}_PORT=\"${eg_port}\"")
    fi
    EG_TUNNELS="${EG_TUNNELS} ${name}"       # first tunnel added is the default
    eg_port=$((eg_port + 1))
    ok "egress '${name}' declared"
}

# --- from --egress specs, if any ---------------------------------------------
spec_egress() {   # name,endpoint,pubkey,address[,psk]  |  name,conf=<path>
    local spec="$1"
    local name="${spec%%,*}" rest="${spec#*,}"
    valid_name "$name" || die "invalid egress name in --egress: ${spec}"
    [[ " $(egress_list) " == *" $name "* ]] && die "--egress declares '${name}' twice"
    if [[ "$rest" == conf=* ]]; then
        EG_BLOCKS+=("EGRESS_${name}_TYPE=\"tunnel\"
EGRESS_${name}_CONF_FILE=\"${rest#conf=}\"
EGRESS_${name}_PORT=\"${eg_port}\"")
    else
        local IFS=','; read -r _ endpoint pubkey address psk <<<"$spec"; unset IFS
        [[ -n "${endpoint:-}" && -n "${pubkey:-}" && -n "${address:-}" ]] \
            || die "--egress ${name} needs name,endpoint,pubkey,address (or name,conf=<path>)"
        EG_BLOCKS+=("EGRESS_${name}_TYPE=\"tunnel\"
EGRESS_${name}_PROTO=\"wg\"
EGRESS_${name}_ENDPOINT=\"${endpoint}\"
EGRESS_${name}_PUBKEY=\"${pubkey}\"
EGRESS_${name}_PRIVKEY=\"$(wg genkey)\"
EGRESS_${name}_PSK=\"${psk:-}\"
EGRESS_${name}_ADDRESS=\"${address}\"
EGRESS_${name}_PORT=\"${eg_port}\"")
    fi
    EG_TUNNELS="${EG_TUNNELS} ${name}"
    eg_port=$((eg_port + 1))
    ok "egress '${name}' declared"
}

if [[ ${#EGRESS_ARGS[@]} -gt 0 ]]; then
    for spec in "${EGRESS_ARGS[@]}"; do spec_egress "$spec"; done
elif [[ "$(ask_yn "Add a tunnel egress now?" "no")" == yes ]]; then
    # No limit: keep asking until they stop. Several exits is the normal case
    # for anyone routing different destinations to different places.
    add_tunnel_egress
    while [[ "$(ask_yn "Add another?" "no")" == yes ]]; do add_tunnel_egress; done
else
    note "Single-hop for now. Add one later with: gw-egress add <name> ..."
fi

# A profile can reference an exit it has no way to create. Ask for it here,
# where the name is already known, rather than leaving a rule pointing at
# nothing for the installer to reject later.
if [[ -n "$PROFILE" && -r "$PROF_FILE" ]]; then
    for need in $(profile_meta "$PROF_FILE" requires-egress); do
        [[ " $(egress_list) " == *" $need "* ]] && continue
        note "Profile '${PROFILE}' routes some traffic through an exit named '${need}'."
        if [[ "$(ask_yn "Declare '${need}' now?" "no")" == yes ]]; then
            add_tunnel_egress "$need"
        fi
    done
fi

EGRESS_LIST="$(egress_list)"

# =============================================================================
step "Ingress — who connects"
# =============================================================================
note "One channel per group you would revoke, isolate or route separately."
note "A leaked config then costs you one channel, not the gateway."
if [[ -n "$CHANNELS_ARG" ]]; then CHANNELS="$CHANNELS_ARG"
else CHANNELS="$(ask "Channel names, space separated" "family")"; fi
[[ -n "$CHANNELS" ]] || CHANNELS="family"

default_eg="${EGRESS_LIST%% *}"
in_port=51820; net_third=10
declare -a CH_BLOCKS=()
for c in $CHANNELS; do
    if ! valid_name "$c"; then warn "skipping invalid channel name '${c}'"; continue; fi
    printf '  %s%s%s\n' "$BOLD" "$c" "$NC"
    ctype="$(ask_one "  protocol — wg is faster, awg survives DPI (wg/awg)" "$PROF_TYPE" wg awg)"
    if [[ "$ctype" == "awg" ]]; then cmtu="$PROF_MTU_AWG"; else cmtu="$PROF_MTU_WG"; fi
    ciso="$(ask_yn "  isolate — clients cannot see each other or any other channel?" "no")"
    cegr="$(ask_one "  default egress" "$default_eg" $EGRESS_LIST)"
    CH_BLOCKS+=("INGRESS_${c}_TYPE=\"${ctype}\"
INGRESS_${c}_PORT=\"${in_port}\"
INGRESS_${c}_NET=\"10.30.${net_third}.0/24\"
INGRESS_${c}_MTU=\"${cmtu}\"
INGRESS_${c}_EGRESS=\"${cegr}\"
INGRESS_${c}_ISOLATE=\"${ciso}\"
INGRESS_${c}_REACH=\"\"")
    ok "${c}: ${ctype} on UDP ${in_port}, 10.30.${net_third}.0/24, out via ${cegr}$([[ "$ciso" == yes ]] && echo ', isolated')"
    in_port=$((in_port + 1)); net_third=$((net_third + 10))
done
[[ ${#CH_BLOCKS[@]} -gt 0 ]] || die "no valid channels — nothing to install"

# =============================================================================
step "DNS"
# =============================================================================
note "Client DNS is redirected to this gateway either way; clients cannot pick"
note "their own resolver. The filter adds blocklists and a query log on top."
DNS_FILTER="$(ask_yn "Run the filtering resolver (AdGuardHome)?" "yes")"

# =============================================================================
step "Write"
# =============================================================================
[[ -e "$OUT" ]] && cp -a "$OUT" "${OUT}.bak-$(date +%Y%m%d-%H%M%S)"
{
    echo "# or-katan configuration — written by setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Change it by hand, or with: gw-config set <key> <value>"
    echo
    echo "GATEWAY_HOST=\"${HOST}\""
    [[ -n "$PROFILE" ]] && echo "GATEWAY_PROFILE=\"${PROFILE}\""
    echo
    echo "EGRESS_PATHS=\"${EGRESS_LIST}\""
    echo "EGRESS_direct_TYPE=\"direct\""
    for b in ${EG_BLOCKS[0]+"${EG_BLOCKS[@]}"}; do echo; echo "$b"; done
    echo
    echo "INGRESS_CHANNELS=\"${CHANNELS}\""
    for b in "${CH_BLOCKS[@]}"; do echo; echo "$b"; done
    echo
    # Delimited so `gw-config profile` can replace the whole block later —
    # parked rules and their instructions included, which would otherwise
    # outlive the profile that wrote them.
    echo "# --- policy: begin (managed by gw-config profile) ---"
    if [[ -n "$PROFILE" && -r "$PROF_FILE" ]]; then
        echo "# From profile '${PROFILE}'."
        # Any rule whose egress was never declared is parked: commented out and
        # dropped from POLICY_RULES, so the config installs and the rule is one
        # uncomment away once the exit exists.
        body="$(grep -vE '^# (title|summary|ingress-type|ingress-mtu|requires-egress|note):' "$PROF_FILE")"
        live=""; parked=""
        for r in $(printf '%s\n' "$body" | sed -nE 's|^POLICY_RULES="(.*)"$|\1|p'); do
            target="$(printf '%s\n' "$body" | sed -nE "s|^POLICY_${r}_EGRESS=\"(.*)\"\$|\\1|p")"
            if [[ " ${EGRESS_LIST} " == *" ${target} "* ]]; then live="${live} ${r}"; else parked="${parked} ${r}"; fi
        done
        printf 'POLICY_RULES="%s"\n' "${live# }"
        printf '%s\n' "$body" | grep -vE '^POLICY_RULES=' | while IFS= read -r line; do
            park=no
            for r in $parked; do [[ "$line" == "POLICY_${r}_"* ]] && park=yes; done
            [[ "$park" == yes ]] && printf '#%s\n' "$line" || printf '%s\n' "$line"
        done
        if [[ -n "$parked" ]]; then
            echo
            echo "# The rule(s)${parked} are commented out: they route to an egress path that"
            echo "# does not exist yet. Declare it with 'gw-egress add', uncomment these lines,"
            echo "# add the rule name back to POLICY_RULES, and run 'gw-config apply'."
        fi
    else
        echo "POLICY_RULES=\"\""
    fi
    echo "# --- policy: end ---"
    echo
    echo "DNS_STACK=\"yes\""
    echo "DNS_FILTER_ENABLE=\"${DNS_FILTER}\""
    echo "DNS_EGRESS=\"${default_eg}\""
    echo "DNSCRYPT_RESOLVERS=\"google quad9-doh-ip4-port443-filter-pri\""
    echo "DNS_FALLBACK=\"8.8.8.8\""
    echo
    echo "SSH_PORT=\"22\""
    echo "IPV6_HARDEN=\"no\""
} > "$OUT"
chmod 600 "$OUT" 2>/dev/null || true
ok "wrote ${OUT}"

# The profile may name an egress it cannot create. Say so now, while the person
# who has to fix it is still looking.
if [[ -n "$PROFILE" && -r "$PROF_FILE" ]]; then
    for need in $(profile_meta "$PROF_FILE" requires-egress); do
        [[ " $EGRESS_LIST " == *" $need "* ]] && continue
        warn "rules needing the '${need}' exit are commented out — the rest of the profile is active"
        note "gw-egress add ${need} --endpoint <host>:<port> --pubkey <key> --address <ip/cidr>"
        note "then uncomment them in ${OUT}, add them back to POLICY_RULES, and: gw-config apply"
    done
    while IFS= read -r n; do [[ -n "$n" ]] && note "$n"; done \
        < <(profile_meta "$PROF_FILE" note)
fi

# =============================================================================
step "Next"
# =============================================================================
echo "    Ports to open on the router or cloud firewall:"
for b in "${CH_BLOCKS[@]}"; do
    echo "$b" | grep -E '_PORT=' | sed -E 's|.*"([0-9]+)".*|      UDP \1|'
done
echo
if [[ $EUID -eq 0 && "$(ask_yn "Install now?" "yes")" == yes ]]; then
    exec "${KIT_DIR}/install.sh"
fi
echo "    Review it, then:  sudo ./install.sh"
