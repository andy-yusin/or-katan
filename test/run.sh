#!/usr/bin/env bash
# Install the kit into a throwaway privileged container and check it came up.
#
#   test/run.sh                       # the shipped example config (single-hop)
#   test/run.sh multi-channel         # 3 channels, 3 egress paths, isolation
#   test/run.sh policy-seeds          # per-destination egress with ipset seeds
#   test/run.sh multi-channel --shell # same, but drop into a shell at the end
#
# Two things a container cannot give us, and what we do instead:
#   * no kernel WireGuard  -> wireguard-go, the userspace implementation
#   * no AmneziaWG DKMS    -> shims that strip the obfuscation keys and use wg,
#                             so the awg code path is still walked end to end
# Everything else — iptables, ipset, policy routing, dnsmasq, dnscrypt — is real.
set -euo pipefail

cd "$(dirname "$0")/.."
FIXTURE="${1:-}"; [[ "${FIXTURE:-}" == --* ]] && FIXTURE=""
SHELL_AT_END=no; for a in "$@"; do [[ "$a" == "--shell" ]] && SHELL_AT_END=yes; done

if [[ -n "$FIXTURE" ]]; then
    CONF="test/fixtures/${FIXTURE}.conf"
    [[ -f "$CONF" ]] || { echo "no such fixture: $CONF" >&2; exit 1; }
else
    CONF="gateway.conf.example"
fi
echo "==> fixture: $CONF"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

# Some hosts leave the container unable to resolve the apt mirrors. Set
# DOCKER_DNS=8.8.8.8 (or whatever works for you) if the install step reports
# "Unable to locate package".
DNS_ARGS=()
[[ -n "${DOCKER_DNS:-}" ]] && DNS_ARGS=(--dns "$DOCKER_DNS")

INNER=$(cat <<'EOF'
set -e
cp -r /kit /work && cp /conf /work/gateway.conf
mkdir -p /usr/local/sbin && cp /work/test/shims/* /usr/local/sbin/
export PATH=/usr/local/sbin:$PATH DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq iproute2 procps wireguard-go wireguard-tools iptables \
    ipset dnsmasq dnscrypt-proxy qrencode dnsutils curl ca-certificates >/dev/null 2>&1
export WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go
mkdir -p /dev/net && [ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200

# The shipped example deliberately leaves GATEWAY_HOST empty, and the installer
# is right to refuse it. Give it a name so the rest of the run has something.
sed -i 's#^GATEWAY_HOST="\(\|gw\.example\.com\)"#GATEWAY_HOST="gw.test.example"#' /work/gateway.conf

# Fixtures carry NAME_PUB / NAME_PRIV placeholders so no key is ever committed.
for k in $(grep -oE '\b[A-Z]+_PRIV\b' /work/gateway.conf | sed 's/_PRIV//' | sort -u); do
    P=$(wg genkey); U=$(echo "$P" | wg pubkey)
    sed -i "s#${k}_PRIV#${P}#; s#${k}_PUB#${U}#" /work/gateway.conf
done

cd /work
echo "==> install"
./install.sh > /tmp/install.log 2>&1 || { echo "INSTALL FAILED"; tail -30 /tmp/install.log; exit 1; }

echo "==> gw-doctor"
gw-doctor || true

echo
echo "==> gw-egress"
gw-egress || true

echo
echo "==> MSS clamping"
iptables -t mangle -S FORWARD | grep -q TCPMSS \
    && echo "  forwarded client traffic is clamped" \
    || echo "  MSS BROKEN: no FORWARD clamp"
miss=""
for e in $(. /work/gateway.conf; echo "$EGRESS_PATHS"); do
    t=$(. /work/gateway.conf; eval "echo \${EGRESS_${e}_TYPE:-}")
    if [ -n "$t" ] && [ "$t" != direct ]; then
        iptables -t mangle -S POSTROUTING | grep -q -- "-o out-${e} .*TCPMSS" || miss="${miss} out-${e}"
    fi
done
[ -z "$miss" ] && echo "  the gateway's own tunnelled traffic is clamped too" \
              || echo "  MSS BROKEN: no POSTROUTING clamp on:${miss}"

echo
echo "==> issue a client on every channel and re-check"
# gw-client channels prints a table for humans; take the names from the config.
for c in $(. /work/gateway.conf; echo "$INGRESS_CHANNELS"); do
    gw-client add "test-$c" --channel "$c" >/dev/null 2>&1 \
        && echo "  added test-$c on $c" || echo "  FAILED to add on $c"
done
gw-client list || true

echo
echo "==> config CLI"
gw-config validate >/dev/null 2>&1 && echo "  gw-config validate: ok" || echo "  gw-config validate: FAILED"
n=$(gw-config profiles 2>/dev/null | grep -cE "^  [a-z]") || n=0
echo "  profiles listed: $n"
h=$(gw-config get GATEWAY_HOST 2>/dev/null) && echo "  reads a plain key: $h" || echo "  FAILED to read GATEWAY_HOST"
c=$(. /work/gateway.conf; echo "$INGRESS_CHANNELS" | awk '{print $1}')
k=$(gw-config get "INGRESS_${c}_NET" 2>/dev/null) && echo "  reads a per-object key: INGRESS_${c}_NET=$k" \
    || echo "  FAILED to read INGRESS_${c}_NET"
# A value the installer must reject, to prove the rollback path is wired up.
if gw-config set "INGRESS_${c}_NET" "not-a-subnet" >/dev/null 2>&1; then
    echo "  ROLLBACK BROKEN: an invalid value was accepted"
else
    [ "$(gw-config get "INGRESS_${c}_NET")" = "$k" ] \
        && echo "  rejects an invalid value and rolls back" \
        || echo "  ROLLBACK BROKEN: value is now $(gw-config get "INGRESS_${c}_NET")"
fi


# Only the fixtures that subscribe a rule to a feed exercise this.
if grep -q "^POLICY_[a-z_]*_FEED=" /work/gateway.conf; then
    echo
    echo "==> policy feeds"
    fr=$(grep -oE "^POLICY_[a-z_]+_FEED=" /work/gateway.conf | sed -E "s/^POLICY_(.*)_FEED=$/\1/" | head -1)
    n=$(ipset list "gwpf_${fr}" 2>/dev/null | awk "/Number of entries/{print \$4}") || n=0
    # The list carries 150 usable prefixes and four the sanitiser must drop.
    [ "${n:-0}" = "150" ] && echo "  ${fr}: ${n} prefixes loaded, junk lines dropped" \
                          || echo "  FEED BROKEN: gwpf_${fr} holds ${n:-0}, expected 150"
    ipset list "gwpf_${fr}" 2>/dev/null | grep -qE "^(10\.|192\.168\.|0\.0\.0\.0)" \
        && echo "  FEED BROKEN: a private or default range survived the sanitiser" \
        || echo "  private and 0.0.0.0/0 entries rejected"
    # Fail closed: a dead source must leave the loaded list alone.
    gw-config --no-apply set "POLICY_${fr}_FEED" "https://127.0.0.1:9/gone.txt" >/dev/null 2>&1 || true
    gw-feeds update >/dev/null 2>&1 || true
    n2=$(ipset list "gwpf_${fr}" 2>/dev/null | awk "/Number of entries/{print \$4}") || n2=0
    [ "${n2:-0}" = "150" ] && echo "  a dead source leaves the previous list loaded" \
                           || echo "  FEED BROKEN: a failed fetch emptied the set (${n2:-0} left)"
    gw-config --no-apply set "POLICY_${fr}_FEED" "file:///work/test/fixtures/policy-feed.list" >/dev/null 2>&1 || true
fi

# Only the fixtures that hold a rule back from some address space exercise this.
if grep -q "^POLICY_[a-z_]*_EXCLUDE_FEED=" /work/gateway.conf; then
    echo
    echo "==> policy exclusions"
    xr=$(grep -oE "^POLICY_[a-z_]+_EXCLUDE_FEED=" /work/gateway.conf | sed -E "s/^POLICY_(.*)_EXCLUDE_FEED=$/\1/" | head -1)
    n=$(ipset list "gwpx_${xr}" 2>/dev/null | awk "/Number of entries/{print \$4}") || n=0
    # Two prefixes from the list plus one static EXCLUDE_CIDRS; the private range is dropped.
    [ "${n:-0}" = "3" ] && echo "  ${xr}: ${n} prefixes excluded, the private range dropped" \
                        || echo "  EXCLUDE BROKEN: gwpx_${xr} holds ${n:-0}, expected 3"
    # Every one of the rule's matches must carry the negative match, and none may be without it.
    have=$(iptables -t mangle -S PREROUTING | grep -c "match-set gwp[df]*_${xr} dst -m set ! --match-set gwpx_${xr} dst") || have=0
    bare=$(iptables -t mangle -S PREROUTING | grep "match-set gwp[df]*_${xr} dst" | grep -vc "gwpx_${xr}") || bare=0
    [ "$have" -ge 3 ] && [ "$bare" = "0" ] && echo "  all ${have} matches for '${xr}' carry the exclusion" \
                                           || echo "  EXCLUDE BROKEN: ${have} matches carry it, ${bare} do not"
    ipset test "gwpx_${xr}" 198.18.7.1 >/dev/null 2>&1 && ipset test "gwpf_${xr}" 198.18.7.1 >/dev/null 2>&1 \
        && echo "  198.18.7.1 is in the feed and in the exclusion — the exclusion wins" \
        || echo "  EXCLUDE BROKEN: 198.18.7.1 should be in both gwpf_${xr} and gwpx_${xr}"
    ipset test "gwpx_${xr}" 192.0.2.1 >/dev/null 2>&1 && ipset test "gwp_${xr}" 192.0.2.1 >/dev/null 2>&1 \
        && echo "  a static seed is held back by a static exclusion too" \
        || echo "  EXCLUDE BROKEN: 192.0.2.1 should be in both gwp_${xr} and gwpx_${xr}"
    # A source that stops answering must leave its last good copy in place.
    mv /work/test/fixtures/policy-exclude.list /work/test/fixtures/policy-exclude.list.gone
    gw-feeds update "$xr" >/dev/null 2>&1 || true
    n2=$(ipset list "gwpx_${xr}" 2>/dev/null | awk "/Number of entries/{print \$4}") || n2=0
    mv /work/test/fixtures/policy-exclude.list.gone /work/test/fixtures/policy-exclude.list
    [ "${n2:-0}" = "3" ] && echo "  a dead exclusion source keeps its last good copy" \
                         || echo "  EXCLUDE BROKEN: a failed fetch changed the set (${n2:-0} left)"
fi

# Only the fixtures that give a path somewhere to go exercise this.
if grep -q "^EGRESS_[a-z_]*_FAILOVER=" /work/gateway.conf; then
    echo
    echo "==> egress failover"
    fe=$(grep -oE "^EGRESS_[a-z_]+_FAILOVER=" /work/gateway.conf | sed -E "s/^EGRESS_(.*)_FAILOVER=$/\1/" | head -1)
    fb=$(. /work/gateway.conf; eval "echo \$EGRESS_${fe}_FAILOVER" | awk '{print $1}')
    tbl="gw_${fe}"
    if [ "$fb" = "direct" ]; then
        want=$(ip route show default | awk '{print $5; exit}')
    else
        want="out-${fb}"
    fi
    table_dev() { ip route show table "$1" 2>/dev/null \
        | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'; }

    # Nothing in here answers a probe, so two checks — enough to cross the
    # threshold and scan the candidates — must still change nothing.
    gw-health check >/dev/null 2>&1 || true
    gw-health check >/dev/null 2>&1 || true
    [ -z "$(gw-health substitutions)" ] \
        && echo "  no substitute is invented when nothing is healthy" \
        || echo "  HEALTH BROKEN: failed over to a path that never answered"

    # The mechanism itself, driven by hand: one route moves and everything
    # pointed at that path follows it.
    gw-health switch "$fe" "$fb" >/dev/null 2>&1 || true
    d=$(table_dev "$tbl")
    [ "$d" = "$want" ] && echo "  ${tbl} follows the substitution to ${want}" \
                       || echo "  HEALTH BROKEN: ${tbl} points at ${d:-nothing}, expected ${want}"
    dr=$(gw-doctor 2>&1 || true)
    if echo "$dr" | grep -aq "LEAKING"; then
        echo "  HEALTH BROKEN: gw-doctor reads a live failover as a leak"
    elif echo "$dr" | grep -aq "carried by"; then
        echo "  gw-doctor reports the failover rather than a leak"
    else
        echo "  HEALTH BROKEN: gw-doctor says nothing about a failover in force"
    fi

    gw-health back "$fe" >/dev/null 2>&1 || true
    d=$(table_dev "$tbl")
    [ "$d" = "out-${fe}" ] && echo "  back on its own path after 'gw-health back'" \
                           || echo "  HEALTH BROKEN: after 'back', ${tbl} points at ${d:-nothing}"
fi

echo
echo "==> snapshots"
# Taken by the installer already; this asserts what is in it and that putting
# it back works, which is the only thing that makes a backup worth having.
arc=$(ls -1t /var/backups/gateway/gateway-*.tar.gz 2>/dev/null | head -1)
if [ -z "$arc" ]; then
    echo "  BACKUP BROKEN: the installer took no snapshot"
else
    [ "$(stat -c %a "$arc")" = "600" ] && [ "$(stat -c %a /var/backups/gateway)" = "700" ] \
        && echo "  archive is 0600 in a 0700 directory" \
        || echo "  BACKUP BROKEN: $(stat -c %a /var/backups/gateway)/$(stat -c %a "$arc") — key material is readable"
    for want in ./config/etc/gateway/gateway.conf ./manifest.txt ./state/iptables.rules; do
        tar -tzf "$arc" | grep -qx "$want" || echo "  BACKUP BROKEN: ${want} is not in the archive"
    done
    tar -tzf "$arc" | grep -qx ./config/etc/gateway/gateway.conf && echo "  holds the config, manifest and live state"
    # A restore has to actually put a changed file back.
    was=$(gw-config get GATEWAY_HOST)
    gw-config --no-apply set GATEWAY_HOST "wrecked.example" >/dev/null 2>&1 || true
    gw-backup restore "$arc" >/dev/null 2>&1 || true
    [ "$(gw-config get GATEWAY_HOST)" = "wrecked.example" ] \
        && echo "  a restore without --yes changes nothing" \
        || echo "  BACKUP BROKEN: restore wrote without being asked to"
    gw-backup restore "$arc" --yes >/dev/null 2>&1 || true
    [ "$(gw-config get GATEWAY_HOST)" = "$was" ] \
        && echo "  restore --yes puts the config back" \
        || echo "  BACKUP BROKEN: after restore GATEWAY_HOST is $(gw-config get GATEWAY_HOST), expected ${was}"
    if grep -q '^BACKUP_EXTRA="/' /work/gateway.conf; then
        tar -tzf "$arc" | grep -q '^\./extra/' \
            && echo "  BACKUP_EXTRA landed in extra/, outside what a restore writes" \
            || echo "  BACKUP BROKEN: BACKUP_EXTRA is set but extra/ is empty"
    fi
    n=$(ls -1 /var/backups/gateway/gateway-*.tar.gz | wc -l | tr -d ' ')
    [ "$n" -ge 2 ] && echo "  restore took its own snapshot first (${n} on disk)" \
                   || echo "  BACKUP BROKEN: restore did not snapshot what it was about to overwrite"
fi

echo
echo "==> idempotency: install again, rule counts must not move"
before="$(ip rule show | wc -l):$(iptables-save | wc -l):$(ip -o link show | wc -l)"
./install.sh > /tmp/install2.log 2>&1 || { echo "REINSTALL FAILED"; tail -20 /tmp/install2.log; exit 1; }
after="$(ip rule show | wc -l):$(iptables-save | wc -l):$(ip -o link show | wc -l)"
[ "$before" = "$after" ] && echo "  stable ($after)" || echo "  DRIFT: $before -> $after"
EOF
)

if [[ "$SHELL_AT_END" == yes ]]; then
    INNER+=$'\necho; echo "==> shell (exit to tear down)"; exec bash'
    exec docker run --rm --privileged -it ${DNS_ARGS[0]:+"${DNS_ARGS[@]}"} \
        -v "$PWD:/kit:ro" -v "$PWD/$CONF:/conf:ro" \
        ubuntu:24.04 bash -c "$INNER"
fi

exec docker run --rm --privileged ${DNS_ARGS[0]:+"${DNS_ARGS[@]}"} \
    -v "$PWD:/kit:ro" -v "$PWD/$CONF:/conf:ro" \
    ubuntu:24.04 bash -c "$INNER"
