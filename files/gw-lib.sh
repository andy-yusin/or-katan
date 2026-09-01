#!/bin/bash
#
# gw-lib.sh — helpers shared by the tools that write gateway.conf.
#
# Sourced, never executed. Expects $CONF_FILE to be set by the caller.
#
# The writer lives here because gw-config and gw-egress are both writers, and a
# second copy is a second place for the same defect to survive being fixed.

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
