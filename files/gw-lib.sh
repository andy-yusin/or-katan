#!/bin/bash
#
# gw-lib.sh — helpers shared by more than one gateway tool.
#
# Sourced, never executed. Expects $CONF_FILE to be set by the caller.
#
# The config writer lives here because gw-config and gw-egress are both
# writers, and a second copy is a second place for the same defect to survive
# being fixed. gw-routes.sh deliberately sources nothing — it is the boot path
# — so it carries its own copy of the substitution reader below.

# sed's replacement text is not literal: '&' expands to the whole match and the
# delimiter ends the expression. A value carrying either — an endpoint, a key, a
# path — corrupts the line it is written to, or fails while reporting success.
sed_replacement() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

conf_set() {   # <key> <value>
    local k="$1" v="$2"
    if grep -qE "^${k}=" "$CONF_FILE"; then
        # A key can legitimately appear commented out above its real line; only
        # the uncommented one is rewritten.
        sed -i "s|^${k}=.*|${k}=\"$(sed_replacement "$v")\"|" "$CONF_FILE"
    else
        printf '%s="%s"\n' "$k" "$v" >> "$CONF_FILE"
    fi
}

conf_unset() {   # <key>
    local k="$1"
    grep -qE "^${k}=" "$CONF_FILE" || return 0
    sed -i "/^${k}=/d" "$CONF_FILE"
}

# --- Failover substitutions --------------------------------------------------
# gw-health can carry one egress's traffic on another while its own path is
# down. Every tool that reports where traffic goes has to know, or it reports a
# working failover as a leak. gw-health owns the state; this asks it for it.
health_subs() {
    [[ -x /usr/local/bin/gw-health ]] || return 0
    /usr/local/bin/gw-health substitutions 2>/dev/null || true
}

# The egress actually carrying <egress> right now — itself, unless substituted.
# Callers pass the output of health_subs so one invocation covers a whole
# report rather than one per line.
eg_effective() {   # <egress> <health_subs output>
    local s
    s="$(awk -v e="$1" '$1==e {print $2; exit}' <<< "${2:-}")"
    echo "${s:-$1}"
}
