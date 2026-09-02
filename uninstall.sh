#!/bin/bash
#
# uninstall.sh — remove or-katan.
#
# Stops every channel and egress tunnel, clears routing state, removes the
# tools. Keys and client lists are kept unless you pass --purge: deleting them
# permanently invalidates every client config ever issued.
#
set -uo pipefail

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$CYAN" "$NC" "$1"; }
ok()   { printf '    %s✓%s %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$NC" "$1"; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
PURGE="no"; [[ "${1:-}" == "--purge" ]] && PURGE="yes"

ETC_DIR="/etc/gateway"
CONF="${ETC_DIR}/gateway.conf"
INGRESS_CHANNELS=""; EGRESS_PATHS=""
# shellcheck disable=SC1090
[[ -r "$CONF" ]] && { . "$CONF"; } 2>/dev/null || true

cfg() { local v="$1"; echo "${!v-}"; }
ch_type() { local t; t="$(cfg "INGRESS_${1}_TYPE")"; echo "${t:-wg}"; }
eg_type() { local t; t="$(cfg "EGRESS_${1}_TYPE")"; [[ -n "$t" ]] || { [[ "$1" == "direct" ]] && t="direct" || t=""; }; echo "$t"; }
eg_proto(){ local p; p="$(cfg "EGRESS_${1}_PROTO")"; echo "${p:-wg}"; }

step "Stopping ingress channels"
for c in $INGRESS_CHANNELS; do
    if [[ "$(ch_type "$c")" == "awg" ]]; then unit="awg-quick@in-${c}"; down="awg-quick"; else unit="wg-quick@in-${c}"; down="wg-quick"; fi
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    # Explicit teardown too: an interface brought up by hand belongs to no unit
    # and would otherwise be left running with nothing behind it.
    if ip link show "in-${c}" &>/dev/null; then
        $down down "in-${c}" >/dev/null 2>&1 || ip link del "in-${c}" 2>/dev/null || true
    fi
    ok "channel ${c} stopped"
done

step "Stopping egress tunnels"
for e in $EGRESS_PATHS; do
    [[ "$(eg_type "$e")" == "tunnel" ]] || continue
    if [[ "$(eg_proto "$e")" == "awg" ]]; then unit="awg-quick@out-${e}"; down="awg-quick"; else unit="wg-quick@out-${e}"; down="wg-quick"; fi
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    if ip link show "out-${e}" &>/dev/null; then
        $down down "out-${e}" >/dev/null 2>&1 || ip link del "out-${e}" 2>/dev/null || true
    fi
    ok "egress ${e} stopped"
done

step "Clearing routing state"
for c in $INGRESS_CHANNELS; do
    [[ -x "${ETC_DIR}/gw-routes.sh" ]] && "${ETC_DIR}/gw-routes.sh" down "$c" >/dev/null 2>&1
done
for e in $EGRESS_PATHS; do ip route flush table "gw_${e}" 2>/dev/null; done
ip route flush table gw_local 2>/dev/null
for s in $(ipset list -n 2>/dev/null | grep -E '^gwp?d?_' || true); do
    ipset destroy "$s" 2>/dev/null && ok "ipset ${s} removed"
done
# The rt_tables entries are left: they are inert lines, and editing that file
# risks clobbering entries other tools wrote.
ok "routing tables and rules cleared"

step "Removing tools and units"
rm -f /usr/local/bin/gw-client /usr/local/bin/gw-egress /usr/local/bin/gw-doctor \
      /usr/local/bin/gw-config /usr/local/bin/gw-feeds /usr/local/bin/gw-health \
      /usr/local/bin/gw-setup
systemctl disable --now gw-feeds.timer >/dev/null 2>&1 || true
systemctl disable --now gw-health.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/gw-feeds.timer /etc/systemd/system/gw-feeds.service
rm -f /etc/systemd/system/gw-health.timer /etc/systemd/system/gw-health.service
rm -rf /etc/systemd/system/wg-quick@in-*.service.d /etc/systemd/system/awg-quick@in-*.service.d
rm -f /etc/systemd/system/dnscrypt-proxy.service.d/10-gateway.conf
rm -f /etc/systemd/networkd.conf.d/10-keep-foreign-rules.conf
rm -f /etc/sysctl.d/99-gateway.conf
rmdir /etc/systemd/system/dnscrypt-proxy.service.d 2>/dev/null
systemctl daemon-reload 2>/dev/null
ok "tools and drop-ins removed"

step "DNS filter"
if [[ -f /etc/systemd/system/AdGuardHome.service ]]; then
    systemctl disable --now AdGuardHome >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/AdGuardHome.service
    systemctl daemon-reload 2>/dev/null
    ok "stopped; binary and data left in /opt/AdGuardHome"
else
    ok "not installed"
fi

step "Restoring DNS config"
restored=0
for f in /etc/dnsmasq.conf /etc/dnscrypt-proxy/dnscrypt-proxy.toml; do
    backup="$(ls -1t "${f}".pre-or-katan* 2>/dev/null | head -1)"
    if [[ -n "$backup" ]]; then cp -a "$backup" "$f"; ok "restored $f"; restored=1; fi
done
[[ $restored -eq 0 ]] && warn "no pre-install DNS backups found; /etc/dnsmasq.conf still holds the kit's config"
systemctl restart dnsmasq dnscrypt-proxy >/dev/null 2>&1

step "Keys, clients and configs"
if [[ "$PURGE" == "yes" ]]; then
    rm -rf "$ETC_DIR"
    rm -f /etc/wireguard/in-*.conf /etc/wireguard/out-*.conf
    rm -f /etc/amnezia/amneziawg/in-*.conf /etc/amnezia/amneziawg/out-*.conf
    # The timestamped backups hold the same private keys; a purge that left
    # them behind would not be one.
    rm -f /etc/wireguard/*.conf.bak-* /etc/amnezia/amneziawg/*.conf.bak-*
    # Cached feed lists and any failover substitution still in force. Not
    # secret, but they are gateway state and a purge
    # that left them would repopulate the sets on the next install.
    rm -rf /var/lib/gateway
    ok "deleted — every client config ever issued is now permanently invalid"
else
    cat <<EOF
    Kept, so you can reinstall or move to another host:
      ${ETC_DIR}/keys/            gateway private keys
      ${ETC_DIR}/clients/         issued client configs
      ${ETC_DIR}/awg-params.conf  obfuscation signature
      /etc/wireguard/in-*.conf, /etc/amnezia/amneziawg/in-*.conf   client lists

    ${YELLOW}Re-run with --purge to delete them.${NC}
EOF
fi

printf '\n%sUninstalled.%s Packages (wireguard, dnsmasq, dnscrypt-proxy, ...) were left installed.\n' "$GREEN" "$NC"
