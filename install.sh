#!/bin/bash
#
# gateway-kit installer.
#
#   cp gateway.conf.example gateway.conf && $EDITOR gateway.conf
#   sudo ./install.sh
#
# Safe to re-run: server keys are never rotated and existing clients are never
# dropped. Every step is idempotent.
#
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_SRC="${KIT_DIR}/gateway.conf"
ETC_DIR="/etc/gateway"
CONF_DST="${ETC_DIR}/gateway.conf"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
step() { printf '\n%s==>%s %s%s%s\n' "$CYAN" "$NC" "$BOLD" "$1" "$NC"; }
info() { printf '    %s\n' "$1"; }
ok()   { printf '    %s✓%s %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$NC" "$1"; }
die()  { printf '\n%sERROR:%s %s\n' "$RED" "$NC" "$1" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) die "unknown option: $arg" ;;
    esac
done

# =============================================================================
step "Preflight"
# =============================================================================
[[ $EUID -eq 0 ]] || die "run as root (sudo ./install.sh)"
[[ -r "$CONF_SRC" ]] || die "no gateway.conf here. Start with: cp gateway.conf.example gateway.conf && \$EDITOR gateway.conf"
command -v apt-get >/dev/null || die "this installer targets Debian/Ubuntu (apt-get not found)"
. /etc/os-release 2>/dev/null || true
info "host: ${PRETTY_NAME:-unknown}  kernel $(uname -r)"
[[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]] \
    || warn "untested distribution — expect to adjust package names"

# shellcheck disable=SC1090
source "$CONF_SRC"
: "${GATEWAY_HOST:=}"; : "${INGRESS_CHANNELS:=}"; : "${EGRESS_PATHS:=direct}"; : "${POLICY_RULES:=}"
: "${DNS_STACK:=yes}"; : "${DNS_FILTER_ENABLE:=yes}"; : "${DNS_FILTER_VERSION:=v0.107.68}"
: "${DNS_FILTER_UI_PORT:=80}"; : "${DNS_EGRESS:=}"; : "${DNS_FALLBACK:=8.8.8.8}"
: "${DNSCRYPT_RESOLVERS:=google}"; : "${SSH_PORT:=22}"; : "${IPV6_HARDEN:=no}"

cfg() { local v="$1"; echo "${!v-}"; }
ch_type()  { local t; t="$(cfg "INGRESS_${1}_TYPE")"; echo "${t:-wg}"; }
ch_port()  { cfg "INGRESS_${1}_PORT"; }
ch_net()   { cfg "INGRESS_${1}_NET"; }
ch_mtu()   { local m; m="$(cfg "INGRESS_${1}_MTU")"; [[ -n "$m" ]] || { [[ "$(ch_type "$1")" == "awg" ]] && m=1340 || m=1420; }; echo "$m"; }
ch_egress(){ local e; e="$(cfg "INGRESS_${1}_EGRESS")"; [[ -n "$e" ]] || e="$(echo "$EGRESS_PATHS" | awk '{print $1}')"; echo "$e"; }
ch_iface() { echo "in-$1"; }
ch_conf()  { [[ "$(ch_type "$1")" == "awg" ]] && echo "/etc/amnezia/amneziawg/in-${1}.conf" || echo "/etc/wireguard/in-${1}.conf"; }
ch_unit()  { [[ "$(ch_type "$1")" == "awg" ]] && echo "awg-quick@in-${1}" || echo "wg-quick@in-${1}"; }
eg_type()  { local t; t="$(cfg "EGRESS_${1}_TYPE")"; [[ -n "$t" ]] || { [[ "$1" == "direct" ]] && t="direct" || t=""; }; echo "$t"; }
eg_proto() { local p; p="$(cfg "EGRESS_${1}_PROTO")"; echo "${p:-wg}"; }
eg_iface() { echo "out-$1"; }
eg_conf()  { [[ "$(eg_proto "$1")" == "awg" ]] && echo "/etc/amnezia/amneziawg/out-${1}.conf" || echo "/etc/wireguard/out-${1}.conf"; }
eg_unit()  { [[ "$(eg_proto "$1")" == "awg" ]] && echo "awg-quick@out-${1}" || echo "wg-quick@out-${1}"; }
net_gw()   { echo "${1%.0/24}.1"; }

# --- Validate ---------------------------------------------------------------
[[ -n "$GATEWAY_HOST" && "$GATEWAY_HOST" != "gw.example.com" ]] \
    || die "set GATEWAY_HOST in gateway.conf to this gateway's public hostname or IP"
[[ -n "$INGRESS_CHANNELS" ]] || die "INGRESS_CHANNELS is empty — declare at least one channel"

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_]*$ ]]; }

for e in $EGRESS_PATHS; do
    valid_name "$e" || die "egress name '${e}' must be lowercase [a-z0-9_] and start with a letter"
    [[ ${#e} -le 11 ]] || die "egress name '${e}' is too long (max 11 chars — it becomes interface out-${e})"
    case "$(eg_type "$e")" in
        direct) ;;
        tunnel)
            if [[ -n "$(cfg "EGRESS_${e}_CONF_FILE")" ]]; then
                [[ -r "$(cfg "EGRESS_${e}_CONF_FILE")" ]] || die "EGRESS_${e}_CONF_FILE is not readable"
            else
                [[ -n "$(cfg "EGRESS_${e}_ENDPOINT")" && -n "$(cfg "EGRESS_${e}_PUBKEY")" \
                   && -n "$(cfg "EGRESS_${e}_PRIVKEY")" && -n "$(cfg "EGRESS_${e}_ADDRESS")" ]] \
                    || die "egress '${e}': set ENDPOINT, PUBKEY, PRIVKEY and ADDRESS (or point EGRESS_${e}_CONF_FILE at a provider config)"
            fi
            ;;
        *) die "egress '${e}': EGRESS_${e}_TYPE must be 'tunnel' or 'direct'" ;;
    esac
done

seen_ports=""; seen_nets=""
for c in $INGRESS_CHANNELS; do
    valid_name "$c" || die "channel name '${c}' must be lowercase [a-z0-9_] and start with a letter"
    [[ ${#c} -le 12 ]] || die "channel name '${c}' is too long (max 12 chars — it becomes interface in-${c})"
    [[ "$(ch_type "$c")" =~ ^(wg|awg)$ ]] || die "channel '${c}': TYPE must be 'wg' or 'awg'"
    p="$(ch_port "$c")"; n="$(ch_net "$c")"
    [[ -n "$p" ]] || die "channel '${c}' has no INGRESS_${c}_PORT"
    [[ "$n" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.0/24$ ]] || die "channel '${c}': NET must be a /24 ending in .0/24, got '${n}'"
    [[ " ${seen_ports} " == *" ${p} "* ]] && die "port ${p} is used by more than one channel"
    [[ " ${seen_nets} "  == *" ${n} "*  ]] && die "network ${n} is used by more than one channel"
    seen_ports="${seen_ports} ${p}"; seen_nets="${seen_nets} ${n}"
    e="$(ch_egress "$c")"
    [[ " ${EGRESS_PATHS} " == *" ${e} "* ]] || die "channel '${c}' points at undeclared egress '${e}'"
    for r in $(cfg "INGRESS_${c}_REACH"); do
        [[ " ${INGRESS_CHANNELS} " == *" ${r} "* ]] || die "channel '${c}' REACHes unknown channel '${r}'"
    done
done
for e in $EGRESS_PATHS; do
    [[ "$(eg_type "$e")" == "tunnel" ]] || continue
    p="$(cfg "EGRESS_${e}_PORT")"; [[ -n "$p" ]] || continue
    [[ " ${seen_ports} " == *" ${p} "* ]] && die "egress '${e}' listen port ${p} collides with an ingress port"
    seen_ports="${seen_ports} ${p}"
done
for r in $POLICY_RULES; do
    valid_name "$r" || die "policy name '${r}' must be lowercase [a-z0-9_]"
    e="$(cfg "POLICY_${r}_EGRESS")"
    [[ " ${EGRESS_PATHS} " == *" ${e} "* ]] || die "policy '${r}' names undeclared egress '${e}'"
done
[[ -z "$DNS_EGRESS" || " ${EGRESS_PATHS} " == *" ${DNS_EGRESS} "* ]] \
    || die "DNS_EGRESS '${DNS_EGRESS}' is not a declared egress"

DEF_IF="$(ip route show default | awk '/default/ {print $5; exit}')"
DEF_GW="$(ip route show default | awk '/default/ {print $3; exit}')"
[[ -n "$DEF_IF" && -n "$DEF_GW" ]] || die "no default route on this host"
ok "uplink: ${DEF_IF} via ${DEF_GW}"
ok "ingress: ${INGRESS_CHANNELS}"
ok "egress:  ${EGRESS_PATHS}"

NEED_AWG="no"
for c in $INGRESS_CHANNELS; do [[ "$(ch_type "$c")" == "awg" ]] && NEED_AWG="yes"; done
for e in $EGRESS_PATHS; do
    [[ "$(eg_type "$e")" == "tunnel" && "$(eg_proto "$e")" == "awg" ]] && NEED_AWG="yes"
done

# =============================================================================
step "Packages"
# =============================================================================
export DEBIAN_FRONTEND=noninteractive
PKGS=(wireguard wireguard-tools iptables ipset qrencode dnsutils curl ca-certificates)
[[ "$DNS_STACK" == "yes" ]] && PKGS+=(dnsmasq dnscrypt-proxy)
[[ "$DNS_FILTER_ENABLE" == "yes" ]] && PKGS+=(apache2-utils)

MISSING=()
for p in "${PKGS[@]}"; do dpkg -s "$p" &>/dev/null || MISSING+=("$p"); done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    info "installing: ${MISSING[*]}"
    apt-get update -qq
    apt-get install -y -qq "${MISSING[@]}" >/dev/null
fi
ok "base packages present"

if [[ "$NEED_AWG" == "yes" ]] && ! command -v awg >/dev/null; then
    info "adding the AmneziaWG repository (the kernel module is built via DKMS — a few minutes)"
    apt-get install -y -qq software-properties-common "linux-headers-$(uname -r)" >/dev/null \
        || apt-get install -y -qq software-properties-common >/dev/null
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1 \
        || die "could not add ppa:amnezia/ppa — see https://github.com/amnezia-vpn/amneziawg-linux-kernel-module"
    apt-get update -qq
    apt-get install -y -qq amneziawg amneziawg-dkms amneziawg-tools >/dev/null \
        || die "amneziawg install failed. Kernel headers for $(uname -r) must be available."
fi
if [[ "$NEED_AWG" == "yes" ]]; then
    command -v awg >/dev/null || die "awg is still not on PATH"
    modprobe amneziawg 2>/dev/null || warn "could not modprobe amneziawg yet (a reboot may be needed after the DKMS build)"
    ok "amneziawg available"
fi

# =============================================================================
step "Kernel tuning"
# =============================================================================
cat > /etc/sysctl.d/99-gateway.conf <<EOF
# gateway-kit
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=0
net.ipv6.conf.default.forwarding=0
# Loose reverse-path filtering: policy routing sends replies out an interface
# other than the one they arrived on, and strict rp_filter drops those.
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.tcp_mtu_probing=1
net.netfilter.nf_conntrack_max=262144
net.core.rmem_max=2097152
net.core.wmem_max=2097152
net.core.netdev_max_backlog=5000
EOF
sysctl -q --system >/dev/null 2>&1 || sysctl -q -p /etc/sysctl.d/99-gateway.conf >/dev/null
[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || die "could not enable IPv4 forwarding"
ok "forwarding on, rp_filter loose, conntrack raised"

# =============================================================================
step "Layout"
# =============================================================================
mkdir -p "$ETC_DIR" "${ETC_DIR}/clients" "${ETC_DIR}/keys"
chmod 700 "$ETC_DIR" "${ETC_DIR}/clients" "${ETC_DIR}/keys"
if [[ -f "$CONF_DST" ]] && ! cmp -s "$CONF_SRC" "$CONF_DST"; then
    cp -a "$CONF_DST" "${CONF_DST}.bak-$(date +%Y%m%d-%H%M%S)"
    warn "${CONF_DST} differs from ${CONF_SRC} and is being overwritten (backup kept)"
    warn "note: gw-egress writes channel egress choices into the installed copy — mirror them back"
fi
install -m 600 "$CONF_SRC" "$CONF_DST"
install -m 700 "${KIT_DIR}/files/gw-routes.sh" "${ETC_DIR}/gw-routes.sh"
install -m 755 "${KIT_DIR}/files/gw-client" /usr/local/bin/gw-client
install -m 755 "${KIT_DIR}/files/gw-egress" /usr/local/bin/gw-egress
install -m 755 "${KIT_DIR}/files/gw-doctor" /usr/local/bin/gw-doctor
ok "config at ${CONF_DST}; tools: gw-client, gw-egress, gw-doctor"

# Keys live outside the interface configs so re-running the installer never
# rotates them — that would silently invalidate every client config ever issued.
ensure_key() {
    local name="$1" tool="$2" f="${ETC_DIR}/keys/$1"
    if [[ ! -s "$f" ]]; then
        ( umask 077; $tool genkey > "$f" )
        info "generated a new private key: ${name}" >&2
    fi
    chmod 600 "$f"
    cat "$f"
}

render() {
    local tmpl="$1" out="$2"; shift 2
    local content; content="$(cat "$tmpl")"
    while [[ $# -gt 0 ]]; do
        content="${content//@${1}@/${2}}"; shift 2
    done
    if [[ "$out" == "-" ]]; then printf '%s\n' "$content"; return 0; fi
    printf '%s\n' "$content" > "$out"; chmod 600 "$out"
}

# Re-running must never cost anyone their clients: everything from the first
# [Peer] block onward is carried into the regenerated file.
write_iface_conf() {
    local out="$1"; shift
    local peers=""
    if [[ -f "$out" ]]; then
        peers="$(awk '/^\[Peer\]/{p=1} p' "$out")"
        cp -a "$out" "${out}.bak-$(date +%Y%m%d-%H%M%S)"
        [[ -n "$peers" ]] && info "$(basename "$out"): keeping existing clients, refreshing [Interface]"
    fi
    render "$@"
    [[ -n "$peers" ]] && printf '\n%s\n' "$peers" >> "$out"
    return 0
}

# =============================================================================
step "Egress paths"
# =============================================================================
for e in $EGRESS_PATHS; do
    if [[ "$(eg_type "$e")" == "direct" ]]; then
        ok "${e}: direct via ${DEF_IF}"
        continue
    fi
    conf="$(eg_conf "$e")"
    mkdir -p "$(dirname "$conf")"; chmod 700 "$(dirname "$conf")" 2>/dev/null || true
    src="$(cfg "EGRESS_${e}_CONF_FILE")"
    if [[ -n "$src" ]]; then
        # A provider-supplied config, used verbatim except for the two things
        # that must hold here: wg-quick must not install its own default route,
        # and the listen port must not collide with anything else.
        cp -a "$src" "$conf"; chmod 600 "$conf"
        grep -q '^Table *=' "$conf" && sed -i 's/^Table *=.*/Table = off/' "$conf" \
                                    || sed -i '0,/^\[Peer\]/s//Table = off\n\n[Peer]/' "$conf"
        port="$(cfg "EGRESS_${e}_PORT")"
        if [[ -n "$port" ]]; then
            grep -q '^ListenPort *=' "$conf" && sed -i "s/^ListenPort *=.*/ListenPort = ${port}/" "$conf" \
                                             || sed -i "0,/^\[Interface\]/s//[Interface]\nListenPort = ${port}/" "$conf"
        fi
        ok "${e}: from $(basename "$src") (Table=off enforced)"
    else
        psk_line=""
        [[ -n "$(cfg "EGRESS_${e}_PSK")" ]] && psk_line="PresharedKey = $(cfg "EGRESS_${e}_PSK")"
        render "${KIT_DIR}/templates/egress-tunnel.conf.tmpl" "$conf" \
            EGRESS "$e" ADDRESS "$(cfg "EGRESS_${e}_ADDRESS")" PORT "$(cfg "EGRESS_${e}_PORT")" \
            PRIVKEY "$(cfg "EGRESS_${e}_PRIVKEY")" PUBKEY "$(cfg "EGRESS_${e}_PUBKEY")" \
            PSK_LINE "$psk_line" ENDPOINT "$(cfg "EGRESS_${e}_ENDPOINT")"
        ok "${e}: $(eg_iface "$e") -> $(cfg "EGRESS_${e}_ENDPOINT")"
    fi
done

# =============================================================================
step "Ingress channels"
# =============================================================================
# One obfuscation signature for this gateway, generated randomly. Never copy
# another installation's values: a shared signature lets one fingerprint
# identify every gateway using it.
if [[ "$NEED_AWG" == "yes" ]]; then
    PARAMS_FILE="${ETC_DIR}/awg-params.conf"
    if [[ ! -s "$PARAMS_FILE" ]]; then
        r() { echo $(( RANDOM % ($2 - $1 + 1) + $1 )); }
        big() { od -An -N4 -tu4 /dev/urandom | tr -d ' ' | awk '{print ($1 % 2147483642) + 5}'; }
        JC=$(r 3 10); JMIN=$(r 8 30); JMAX=$(( JMIN + $(r 20 70) ))
        S1=$(r 15 80); S2=$(r 15 80)
        # AmneziaWG requires S1 + 56 != S2, or the init and response packets
        # become indistinguishable and the handshake breaks.
        while [[ $(( S1 + 56 )) -eq $S2 ]]; do S2=$(r 15 80); done
        H1=$(big); H2=$(big); H3=$(big); H4=$(big)
        while [[ "$H2" == "$H1" ]]; do H2=$(big); done
        while [[ "$H3" == "$H1" || "$H3" == "$H2" ]]; do H3=$(big); done
        while [[ "$H4" == "$H1" || "$H4" == "$H2" || "$H4" == "$H3" ]]; do H4=$(big); done
        cat > "$PARAMS_FILE" <<EOF
# AmneziaWG obfuscation signature for this gateway, generated $(date -I).
# Changing any of these disconnects every existing client on every awg channel.
JC=$JC
JMIN=$JMIN
JMAX=$JMAX
S1=$S1
S2=$S2
H1=$H1
H2=$H2
H3=$H3
H4=$H4
EOF
        chmod 600 "$PARAMS_FILE"
        info "generated a fresh obfuscation signature"
    fi
    # shellcheck disable=SC1090
    source "$PARAMS_FILE"
fi

for c in $INGRESS_CHANNELS; do
    conf="$(ch_conf "$c")"; net="$(ch_net "$c")"
    mkdir -p "$(dirname "$conf")"; chmod 700 "$(dirname "$conf")" 2>/dev/null || true
    if [[ "$(ch_type "$c")" == "awg" ]]; then
        write_iface_conf "$conf" "${KIT_DIR}/templates/ingress-awg.conf.tmpl" "$conf" \
            CHANNEL "$c" GW_ADDR "$(net_gw "$net")" PORT "$(ch_port "$c")" \
            PRIVKEY "$(ensure_key "in-${c}.key" awg)" MTU "$(ch_mtu "$c")" \
            JC "$JC" JMIN "$JMIN" JMAX "$JMAX" S1 "$S1" S2 "$S2" H1 "$H1" H2 "$H2" H3 "$H3" H4 "$H4"
    else
        write_iface_conf "$conf" "${KIT_DIR}/templates/ingress-wg.conf.tmpl" "$conf" \
            CHANNEL "$c" GW_ADDR "$(net_gw "$net")" PORT "$(ch_port "$c")" \
            PRIVKEY "$(ensure_key "in-${c}.key" wg)" MTU "$(ch_mtu "$c")"
    fi
    ok "${c}: $(ch_iface "$c") ${net} udp/$(ch_port "$c") ($(ch_type "$c")) -> egress '$(ch_egress "$c")'"
done

# =============================================================================
if [[ "$DNS_STACK" == "yes" ]]; then
step "DNS chain"
policy_servers=""; policy_ipsets=""; fallback_line=""
[[ -n "$DNS_FALLBACK" ]] && fallback_line="server=${DNS_FALLBACK}"

for r in $POLICY_RULES; do
    doms="$(cfg "POLICY_${r}_DOMAINS")"
    [[ -n "$doms" ]] || continue
    # dnsmasq writes each answer into the rule's ipset as the name resolves,
    # which is what makes per-domain egress work without CIDR lists.
    set_list=""
    for d in $doms; do set_list="${set_list}/${d}"; done
    policy_ipsets="${policy_ipsets}ipset=${set_list}/gwpd_${r}"$'\n'
    for s in $(cfg "POLICY_${r}_DNS"); do
        for d in $doms; do policy_servers="${policy_servers}server=/${d}/${s}"$'\n'; done
    done
done

if [[ "$DNS_FILTER_ENABLE" == "yes" ]]; then
    dnsmasq_listen="127.0.0.1"; dnsmasq_port="5353"
else
    # Nothing else would be listening on the channel gateway addresses, and the
    # DNS redirect sends every client query there.
    dnsmasq_listen="127.0.0.1"
    for c in $INGRESS_CHANNELS; do dnsmasq_listen="${dnsmasq_listen},$(net_gw "$(ch_net "$c")")"; done
    dnsmasq_port="53"
    info "DNS filter disabled — dnsmasq serves clients directly on :53 (no filtering or UI)"
fi

ptr_zones=""
for c in $INGRESS_CHANNELS; do
    o="$(ch_net "$c" | awk -F. '{print $3"."$2"."$1}')"
    ptr_zones="${ptr_zones}local=/${o}.in-addr.arpa/"$'\n'
done

if [[ -f /etc/dnsmasq.conf ]] && ! grep -q "gateway-kit" /etc/dnsmasq.conf; then
    cp -a /etc/dnsmasq.conf "/etc/dnsmasq.conf.pre-gateway-kit-$(date +%Y%m%d-%H%M%S)"
    warn "existing /etc/dnsmasq.conf backed up to /etc/dnsmasq.conf.pre-gateway-kit-*"
fi
existing_records=""
[[ -f /etc/dnsmasq.conf ]] && existing_records="$(grep -E '^(address=|ptr-record=)' /etc/dnsmasq.conf || true)"
{
    echo "# Managed by gateway-kit — regenerated by install.sh."
    render "${KIT_DIR}/templates/dnsmasq.conf.tmpl" - \
        DNSMASQ_LISTEN "$dnsmasq_listen" DNSMASQ_PORT "$dnsmasq_port" \
        DNS_FALLBACK_LINE "$fallback_line" POLICY_SERVERS "$policy_servers" \
        POLICY_IPSETS "$policy_ipsets" LOCAL_PTR_ZONES "$ptr_zones"
    [[ -n "$existing_records" ]] && printf '%s\n' "$existing_records"
} > /etc/dnsmasq.conf.new
mv /etc/dnsmasq.conf.new /etc/dnsmasq.conf
chmod 644 /etc/dnsmasq.conf
dnsmasq --test --conf-file=/etc/dnsmasq.conf >/dev/null 2>&1 || die "the generated dnsmasq.conf is invalid (dnsmasq --test)"
ok "dnsmasq on ${dnsmasq_listen}:${dnsmasq_port}"

resolver_list=""
for r in $DNSCRYPT_RESOLVERS; do resolver_list="${resolver_list}${resolver_list:+, }'${r}'"; done
[[ -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml && ! -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml.pre-gateway-kit ]] && \
    cp -a /etc/dnscrypt-proxy/dnscrypt-proxy.toml /etc/dnscrypt-proxy/dnscrypt-proxy.toml.pre-gateway-kit
render "${KIT_DIR}/templates/dnscrypt-proxy.toml.tmpl" /etc/dnscrypt-proxy/dnscrypt-proxy.toml \
    DNSCRYPT_RESOLVERS "$resolver_list"
chmod 644 /etc/dnscrypt-proxy/dnscrypt-proxy.toml
mkdir -p /var/cache/dnscrypt-proxy && chown _dnscrypt-proxy:_dnscrypt-proxy /var/cache/dnscrypt-proxy 2>/dev/null || true

# Debian ships dnscrypt-proxy socket-activated on 127.0.2.1:53, which overrides
# listen_addresses in the toml. The socket units have to go.
systemctl disable --now dnscrypt-proxy.socket >/dev/null 2>&1 || true
systemctl disable --now dnscrypt-proxy-resolvconf.service >/dev/null 2>&1 || true
mkdir -p /etc/systemd/system/dnscrypt-proxy.service.d
cat > /etc/systemd/system/dnscrypt-proxy.service.d/10-gateway.conf <<'EOF'
# Detach from socket activation so listen_addresses in the toml is authoritative.
[Unit]
Requires=
After=network-online.target
Wants=network-online.target

[Service]
Sockets=
EOF
ok "dnscrypt-proxy on 127.0.0.1:5354 (DoH: ${DNSCRYPT_RESOLVERS})"
fi

# =============================================================================
if [[ "$DNS_FILTER_ENABLE" == "yes" ]]; then
step "DNS filter (AdGuardHome)"
AGH_DIR=/opt/AdGuardHome
if [[ ! -x "${AGH_DIR}/AdGuardHome" ]]; then
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64) agh_arch=amd64 ;; arm64) agh_arch=arm64 ;; armhf) agh_arch=armv7 ;;
        *) die "unsupported architecture for AdGuardHome: $arch" ;;
    esac
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    base="https://github.com/AdguardTeam/AdGuardHome/releases/download/${DNS_FILTER_VERSION}"
    tarball="AdGuardHome_linux_${agh_arch}.tar.gz"
    info "downloading ${DNS_FILTER_VERSION} ${agh_arch}"
    curl -fsSL -o "${tmp}/${tarball}" "${base}/${tarball}" || die "download failed: ${base}/${tarball}"
    if curl -fsSL -o "${tmp}/checksums.txt" "${base}/checksums.txt" 2>/dev/null; then
        # Lines look like "<sha256>  ./AdGuardHome_linux_arm64.tar.gz".
        want="$(grep -E "[ /]${tarball}\$" "${tmp}/checksums.txt" | awk '{print $1}' | head -1)"
        [[ -n "$want" ]] || die "no checksum for ${tarball} in the release checksums.txt"
        got="$(sha256sum "${tmp}/${tarball}" | awk '{print $1}')"
        [[ "$want" == "$got" ]] || die "checksum mismatch on ${tarball} — do not install this"
        ok "checksum verified"
    else
        warn "no checksums.txt in the release — proceeding unverified"
    fi
    tar -xzf "${tmp}/${tarball}" -C "$tmp"
    mkdir -p "$AGH_DIR"
    cp "${tmp}/AdGuardHome/AdGuardHome" "${AGH_DIR}/AdGuardHome"
    chmod 755 "${AGH_DIR}/AdGuardHome"
    rm -rf "$tmp"; trap - EXIT
fi

UI_HOST="$(net_gw "$(ch_net "$(echo "$INGRESS_CHANNELS" | awk '{print $1}')")")"
AGH_YAML="${AGH_DIR}/AdGuardHome.yaml"
if [[ ! -f "$AGH_YAML" ]]; then
    FILTER_PASS="$(head -c 15 /dev/urandom | base64 | tr -d '/+=' | head -c 16)"
    FILTER_HASH="$(htpasswd -bnBC 10 "" "$FILTER_PASS" | tr -d ':\n' | sed 's/^\$2y/\$2a/')"
    binds=""
    for c in $INGRESS_CHANNELS; do binds="${binds}    - $(net_gw "$(ch_net "$c")")"$'\n'; done
    cat > "$AGH_YAML" <<EOF
# Managed by gateway-kit. This is the client-facing resolver: it filters, keeps
# per-client stats, and forwards whatever survives to dnsmasq on 127.0.0.1:5353.
http:
  address: ${UI_HOST}:${DNS_FILTER_UI_PORT}
  session_ttl: 720h
users:
  - name: admin
    password: ${FILTER_HASH}
auth_attempts: 5
block_auth_min: 15
theme: auto
dns:
  bind_hosts:
    - 127.0.0.1
${binds}  port: 53
  ratelimit: 20
  refuse_any: true
  upstream_dns:
    - 127.0.0.1:5353
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
  # Used only if the whole dnsmasq chain is unreachable. DoH straight out, so
  # even a total upstream failure puts no plaintext DNS on the local network.
  fallback_dns:
    - https://dns.google/dns-query
  upstream_mode: load_balance
  cache_enabled: true
  cache_size: 4194304
  cache_optimistic: true
  aaaa_disabled: true
filtering:
  protection_enabled: true
  filtering_enabled: true
  rewrites: []
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
user_rules: []
querylog:
  enabled: true
  interval: 168h
statistics:
  enabled: true
  interval: 24h
schema_version: 29
EOF
    chmod 600 "$AGH_YAML"
    echo "$FILTER_PASS" > "${ETC_DIR}/dns-filter-password.txt"
    chmod 600 "${ETC_DIR}/dns-filter-password.txt"
    ok "configured — admin password saved to ${ETC_DIR}/dns-filter-password.txt"
else
    info "AdGuardHome.yaml already present, left untouched"
fi

# It binds :53 on the channel gateway addresses, so those interfaces must exist
# first — both now and on every boot.
after_units=""
for c in $INGRESS_CHANNELS; do after_units="${after_units} $(ch_unit "$c").service"; done
cat > /etc/systemd/system/AdGuardHome.service <<EOF
[Unit]
Description=AdGuard Home: Network-level blocker
After=syslog.target network-online.target${after_units}
Wants=network-online.target

[Service]
Type=simple
ExecStart=${AGH_DIR}/AdGuardHome -s run --no-check-update -w ${AGH_DIR}
WorkingDirectory=${AGH_DIR}
Restart=always
RestartSec=10
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
ok "UI at http://${UI_HOST}:${DNS_FILTER_UI_PORT} (reachable from inside a tunnel only)"
fi

# =============================================================================
step "Services"
# =============================================================================
# systemd-networkd deletes routing policy rules it did not create whenever it
# restarts — and it restarts on any systemd package upgrade. That silently
# strips this gateway's rules while everything still looks up. This is the guard.
mkdir -p /etc/systemd/networkd.conf.d
cat > /etc/systemd/networkd.conf.d/10-keep-foreign-rules.conf <<'EOF'
# gateway-kit: leave routing rules and routes installed by gw-routes.sh alone.
[Network]
ManageForeignRoutingPolicyRules=no
ManageForeignRoutes=no
EOF

# Ingress channels must come up after their egress tunnels, or gw-routes.sh
# points a routing table at an interface that does not exist yet.
egress_units=""
for e in $EGRESS_PATHS; do
    [[ "$(eg_type "$e")" == "tunnel" ]] && egress_units="${egress_units} $(eg_unit "$e").service"
done
for c in $INGRESS_CHANNELS; do
    unit="$(ch_unit "$c")"
    mkdir -p "/etc/systemd/system/${unit}.service.d"
    if [[ -n "$egress_units" ]]; then
        cat > "/etc/systemd/system/${unit}.service.d/10-egress-order.conf" <<EOF
[Unit]
After=${egress_units}
Wants=${egress_units}
EOF
    else
        rm -f "/etc/systemd/system/${unit}.service.d/10-egress-order.conf"
    fi
done
systemctl daemon-reload

start_unit() {
    local unit="$1"
    systemctl enable "$unit" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$unit"; then
        systemctl restart "$unit" || die "$unit failed to restart — journalctl -u $unit -n50"
    else
        systemctl start "$unit" || die "$unit failed to start — journalctl -u $unit -n50"
    fi
}

for e in $EGRESS_PATHS; do
    [[ "$(eg_type "$e")" == "tunnel" ]] || continue
    start_unit "$(eg_unit "$e")"; ok "egress ${e} up"
done
if [[ "$DNS_STACK" == "yes" ]]; then
    start_unit dnscrypt-proxy; ok "dnscrypt-proxy up"
    start_unit dnsmasq;        ok "dnsmasq up"
fi
for c in $INGRESS_CHANNELS; do
    start_unit "$(ch_unit "$c")"; ok "channel ${c} up"
done
[[ "$DNS_FILTER_ENABLE" == "yes" ]] && { start_unit AdGuardHome; ok "DNS filter up"; }

# =============================================================================
step "Verification"
# =============================================================================
if /usr/local/bin/gw-doctor; then
    printf '\n%s%sInstall complete.%s\n' "$GREEN" "$BOLD" "$NC"
else
    printf '\n%s%sInstalled, but gw-doctor reported problems above.%s\n' "$YELLOW" "$BOLD" "$NC"
fi

echo
echo "  Next:"
echo "    ${BOLD}gw-client add \"phone\" --channel $(echo "$INGRESS_CHANNELS" | awk '{print $1}')${NC}"
echo "    ${BOLD}gw-client channels${NC}    what is configured"
echo "    ${BOLD}gw-egress${NC}             where each channel's traffic leaves"
echo "    ${BOLD}gw-doctor${NC}             re-run these checks"
echo
echo "  Forward to this host on the router / cloud firewall:"
for c in $INGRESS_CHANNELS; do
    echo "    UDP $(ch_port "$c")   (channel '${c}')"
done
echo
echo "  Client configs are written to ${ETC_DIR}/clients/."
