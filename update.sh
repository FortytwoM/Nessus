#!/bin/bash
cd /tmp || exit 1

# shellcheck source=/dev/null
[ -f /usr/local/bin/nessus-proxy.sh ] && . /usr/local/bin/nessus-proxy.sh && nessus_export_proxy

LOCK_FILE="/tmp/nessus_update.lock"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [update] $*"
}

if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
    log "Update already in progress (pid $(cat "$LOCK_FILE"))"
    exit 0
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

if [ -z "$1" ]; then
    update_url="${NESSUS_UPDATE_URL:-}"
    if [ -z "$update_url" ]; then
        log "Error: NESSUS_UPDATE_URL not set"
        exit 1
    fi
else
    update_url=$1
fi

log "Downloading plugins from $update_url"
http_code=$(wget -O "all-2.0.tar.gz" "$update_url" --no-check-certificate -q -S 2>&1 | grep -i "HTTP/" | tail -1 | awk '{print $2}')

if [ ! -f "all-2.0.tar.gz" ]; then
    log "Error: Download failed (HTTP ${http_code:-unknown})"
    exit 1
fi

filesize=$(stat -c%s "all-2.0.tar.gz" 2>/dev/null || echo 0)
log "Downloaded: $(($filesize / 1024 / 1024))MB"

if [ "$filesize" -lt 10240 ]; then
    log "Error: File too small (${filesize} bytes)"
    rm -f all-2.0.tar.gz
    exit 1
fi

pkill -f "nessus-service" > /dev/null 2>&1 || true
pkill -f "nessusd" > /dev/null 2>&1 || true
sleep 3

/usr/local/bin/patch.sh --feed-unlock
rm -f /opt/nessus/var/nessus/agent-activity.db 2>/dev/null

log "Installing plugins..."
/opt/nessus/sbin/nessuscli update all-2.0.tar.gz >/dev/null 2>&1
update_result=$?

if [ $update_result -ne 0 ]; then
    log "Error: Plugin installation failed (exit code $update_result)"
    rm -f all-2.0.tar.gz
    exit 1
fi

nasl_count=$(find /opt/nessus/lib/nessus/plugins -maxdepth 1 -name "*.nasl" 2>/dev/null | wc -l)
log "Installed: $nasl_count plugins"

rm -f all-2.0.tar.gz

log "Applying patch..."
/usr/local/bin/patch.sh

log "Starting Nessus..."
/opt/nessus/sbin/nessus-service -D > /dev/null 2>&1 &

log "Compiling plugins (this may take several minutes)..."
waited=0
max_wait=600
while [ $waited -lt $max_wait ]; do
    status=$(curl -sL -k https://localhost:8834/server/status 2>/dev/null)
    if [ -n "$status" ]; then
        engine_state=$(echo "$status" | grep -o '"engine_status":{[^}]*}' | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        plugin_data=$(echo "$status" | sed -n 's/.*"pluginData"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -1)
        engine_progress=$(echo "$status" | grep -o '"engine_status":{[^}]*}' | grep -o '"progress":[0-9]*' | cut -d: -f2)

        if [ "$engine_state" = "ready" ] && [ "$plugin_data" = "true" ]; then
            log "Compilation complete"
            if [ -f /tmp/nessus_feed_immutable ]; then
                exit 0
            fi
            log "Re-applying patch after compile..."
            pkill -f "nessus-service" > /dev/null 2>&1 || true
            pkill -f "nessusd" > /dev/null 2>&1 || true
            sleep 3
            if ! /usr/local/bin/patch.sh; then
                log "Error: Post-compile patch failed"
                exit 1
            fi
            log "Starting Nessus after final patch..."
            /opt/nessus/sbin/nessus-service -D > /dev/null 2>&1 &
            waited2=0
            max_wait2=300
            while [ $waited2 -lt $max_wait2 ]; do
                status=$(curl -sL -k https://localhost:8834/server/status 2>/dev/null)
                if [ -n "$status" ]; then
                    engine_state=$(echo "$status" | grep -o '"engine_status":{[^}]*}' | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
                    plugin_data=$(echo "$status" | sed -n 's/.*"pluginData"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -1)
                    if [ "$engine_state" = "ready" ] && [ "$plugin_data" = "true" ]; then
                        log "Nessus ready after update"
                        exit 0
                    fi
                fi
                sleep 10
                waited2=$((waited2 + 10))
            done
            log "Warning: Nessus did not report ready within ${max_wait2}s after final patch"
            exit 0
        fi

        if [ -n "$engine_progress" ] && [ $((waited % 30)) -eq 0 ]; then
            log "  Compiling: ${engine_progress}%"
        fi
    fi

    sleep 10
    waited=$((waited + 10))
done

log "Warning: Plugin compilation did not finish within ${max_wait}s"
exit 0
