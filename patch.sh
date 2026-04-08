#!/bin/bash

# shellcheck source=/dev/null
[ -f /usr/local/bin/nessus-proxy.sh ] && . /usr/local/bin/nessus-proxy.sh && nessus_export_proxy

PLUGIN_FEED_FILE="/opt/nessus/var/nessus/plugin_feed_info.inc"
PLUGIN_FEED_DOT="/opt/nessus/var/nessus/.plugin_feed_info.inc"
PLUGIN_FEED_LIB="/opt/nessus/lib/nessus/plugins/plugin_feed_info.inc"
PLUGINS_LIB_DIR="/opt/nessus/lib/nessus/plugins"
PLUGIN_SET_CACHE="/opt/nessus/var/nessus/.plugin_set_last"
FEED_IMMUTABLE_MARKER="/tmp/nessus_feed_immutable"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [patch] $*"
}

feed_unlock() {
    if [ -d "$PLUGINS_LIB_DIR" ]; then
        chattr -i -R "$PLUGINS_LIB_DIR" 2>/dev/null || true
    fi
    chattr -i "$PLUGIN_FEED_FILE" "$PLUGIN_FEED_DOT" "$PLUGIN_FEED_LIB" 2>/dev/null || true
    rm -f "$FEED_IMMUTABLE_MARKER"
}

feed_lock() {
    if ! chattr +i "$PLUGIN_FEED_FILE" "$PLUGIN_FEED_DOT" 2>/dev/null; then
        log "Warning: could not set immutable flag on feed files"
        return 1
    fi
    if [ ! -d "$PLUGINS_LIB_DIR" ]; then
        return 0
    fi
    if chattr +i -R "$PLUGINS_LIB_DIR" 2>/dev/null; then
        chattr -i "$PLUGIN_FEED_LIB" 2>/dev/null || true
        chattr -i "$PLUGINS_LIB_DIR" 2>/dev/null || true
        : > "$FEED_IMMUTABLE_MARKER"
        log "Plugin feed metadata locked"
        return 0
    fi
    log "Warning: could not lock plugins directory with chattr"
    chattr -i "$PLUGIN_FEED_FILE" "$PLUGIN_FEED_DOT" 2>/dev/null || true
    return 1
}

if [ "${1:-}" = "--feed-unlock" ]; then
    log "Removing immutable flags from feed files and plugins tree..."
    feed_unlock
    log "Feed unlock finished"
    exit 0
fi

get_plugin_set() {
    local result=""

    result=$(curl -s -k --connect-timeout 10 --max-time 30 https://plugins.nessus.org/v2/plugins.php 2>/dev/null | tr -d '\n\r' | head -c 32)
    if [ -n "$result" ] && echo "$result" | grep -qE '^[0-9]+$'; then
        echo "$result" > "$PLUGIN_SET_CACHE"
        echo "$result"
        return 0
    fi

    local f
    for f in "$PLUGIN_FEED_LIB" "$PLUGIN_FEED_FILE" "$PLUGIN_FEED_DOT"; do
        if [ -f "$f" ]; then
            result=$(grep 'PLUGIN_SET' "$f" 2>/dev/null | grep -o '"[0-9]*"' | tr -d '"')
            if [ -n "$result" ]; then
                echo "$result" > "$PLUGIN_SET_CACHE"
                log "Using plugin set from local files: $result" >&2
                echo "$result"
                return 0
            fi
        fi
    done

    if [ -f "$PLUGIN_SET_CACHE" ]; then
        result=$(cat "$PLUGIN_SET_CACHE")
        if [ -n "$result" ]; then
            log "Using cached plugin set: $result" >&2
            echo "$result"
            return 0
        fi
    fi

    log "Error: Cannot determine plugin set" >&2
    return 1
}

feed_unlock

PLUGIN_SET=$(get_plugin_set)
if [ $? -ne 0 ] || [ -z "$PLUGIN_SET" ]; then
    log "Fatal: Could not determine plugin set"
    exit 1
fi

PATCH_BODY="PLUGIN_SET = \"$PLUGIN_SET\";
PLUGIN_FEED = \"ProfessionalFeed (Direct)\";
PLUGIN_FEED_TRANSPORT = \"Tenable Network Security Lightning\";"

printf '%s\n' "$PATCH_BODY" > "$PLUGIN_FEED_FILE" || { log "Error: Failed to write $PLUGIN_FEED_FILE"; exit 1; }

cp -f "$PLUGIN_FEED_FILE" "$PLUGIN_FEED_DOT" || { log "Error: Failed to copy to $PLUGIN_FEED_DOT"; exit 1; }
mkdir -p "$(dirname "$PLUGIN_FEED_LIB")"
cp -f "$PLUGIN_FEED_FILE" "$PLUGIN_FEED_LIB" || { log "Error: Failed to copy to $PLUGIN_FEED_LIB"; exit 1; }

log "Patch applied (plugin set: $PLUGIN_SET)"
feed_lock || true
