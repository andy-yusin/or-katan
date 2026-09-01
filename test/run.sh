#!/usr/bin/env bash
# Install the kit into a throwaway privileged container and check it came up.
#
#   test/run.sh                       # the shipped example config (single-hop)
#   test/run.sh multi-channel         # 3 channels, 3 egress paths, isolation
#   test/run.sh video-policy          # per-destination egress with ipset seeds
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
echo "==> issue a client on every channel and re-check"
# gw-client channels prints a table for humans; take the names from the config.
for c in $(. /work/gateway.conf; echo "$INGRESS_CHANNELS"); do
    gw-client add "test-$c" --channel "$c" >/dev/null 2>&1 \
        && echo "  added test-$c on $c" || echo "  FAILED to add on $c"
done
gw-client list || true

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
