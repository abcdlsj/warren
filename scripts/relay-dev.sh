#!/usr/bin/env bash

set -euo pipefail

command_name="${1:-up}"
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
relay_port="${BURROW_RELAY_DEV_PORT:-8080}"
if [[ -n "${BURROW_RELAY_URL:-}" ]]; then
    manages_local_relay=0
    relay_url="${BURROW_RELAY_URL%/}"
    if [[ "$relay_url" != https://* ]]; then
        echo "BURROW_RELAY_URL must use https:// so credentials are never sent in plaintext." >&2
        exit 64
    fi
    relay_identity="$(printf '%s' "$relay_url" | shasum -a 256 | cut -c 1-16)"
    default_state_directory="$HOME/Library/Application Support/Burrow/relay-cli/$relay_identity"
else
    manages_local_relay=1
    relay_url="http://127.0.0.1:$relay_port"
    if [[ ! "$relay_port" =~ ^[0-9]+$ ]] || ((relay_port < 1 || relay_port > 65535)); then
        echo "BURROW_RELAY_DEV_PORT must be an integer from 1 to 65535." >&2
        exit 64
    fi
    default_state_directory="$repository_root/.build/relay-dev/$relay_port"
fi
state_directory="${BURROW_RELAY_STATE_DIR:-${BURROW_RELAY_DEV_STATE_DIR:-$default_state_directory}}"
app_executable="$repository_root/Burrow.app/Contents/MacOS/Burrow"

admin_token_file="$state_directory/admin-token"
signing_key_file="$state_directory/signing-key"
host_id_file="$state_directory/host-id"
host_token_file="$state_directory/host-token"
pid_file="$state_directory/relay.pid"
log_file="$state_directory/relay.log"
registry_file="$state_directory/registry.json"
relay_binary="$state_directory/burrow-relay"

usage() {
    cat <<'EOF'
Usage: scripts/relay-dev.sh [up|start|pair|status|stop|logs]

  up      Start a local Relay, register this Mac, launch Burrow, and pair.
  start   Start the Relay without launching or restarting Burrow.
  pair    Generate and open another one-time Web/PWA URL.
  status  Show Relay health and Host presence.
  stop    Stop the local Relay. Burrow and its tmux sessions keep running.
  logs    Follow the local Relay log.

Set BURROW_RELAY_NO_OPEN=1 to print the Web URL without opening a browser.
Set BURROW_RELAY_URL=https://relay.example.com to connect to a deployed Relay.
The first remote connection also needs BURROW_RELAY_ADMIN_TOKEN for provisioning.
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 69
    }
}

prepare_state() {
    mkdir -p "$state_directory"
    chmod 700 "$state_directory"
}

read_secret() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    <"$path" tr -d '\r\n'
}

write_secret() {
    local path="$1"
    local value="$2"
    (umask 077 && printf '%s\n' "$value" >"$path")
}

read_host_token() {
    read_secret "$host_token_file"
}

write_host_token() {
    local host_token="$2"
    write_secret "$host_token_file" "$host_token"
}

json_field() {
    local field="$1"
    /usr/bin/python3 -c 'import json,sys; value=json.load(sys.stdin); print(value[sys.argv[1]])' "$field"
}

relay_pid() {
    local value
    value="$(read_secret "$pid_file" 2>/dev/null || true)"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

relay_is_running() {
    local pid
    pid="$(relay_pid)" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [[ "$(ps -p "$pid" -o command= 2>/dev/null || true)" == "$relay_binary" ]]
}

wait_for_health() {
    for _ in {1..100}; do
        if curl --fail --silent --max-time 1 "$relay_url/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    echo "Relay did not become healthy. See $log_file" >&2
    return 1
}

start_relay() {
    if [[ "$manages_local_relay" != "1" ]]; then
        prepare_state
        wait_for_health
        return
    fi
    prepare_state
    local admin_token signing_key
    admin_token="$(read_secret "$admin_token_file" 2>/dev/null || true)"
    signing_key="$(read_secret "$signing_key_file" 2>/dev/null || true)"
    if [[ -z "$admin_token" ]]; then
        admin_token="$(openssl rand -hex 32)"
        write_secret "$admin_token_file" "$admin_token"
    fi
    if [[ -z "$signing_key" ]]; then
        signing_key="$(openssl rand -hex 32)"
        write_secret "$signing_key_file" "$signing_key"
    fi
    if relay_is_running; then
        wait_for_health
        return
    fi
    if /usr/sbin/lsof -nP -iTCP:"$relay_port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "Port $relay_port is already used by another process." >&2
        echo "Set BURROW_RELAY_DEV_PORT to choose another local port." >&2
        exit 1
    fi
    go build -o "$relay_binary" ./RelayService/cmd/burrow-relay
    BURROW_RELAY_LISTEN="127.0.0.1:$relay_port" \
        BURROW_RELAY_PUBLIC_URL="$relay_url" \
        BURROW_RELAY_ALLOWED_ORIGIN="$relay_url" \
        BURROW_RELAY_ADMIN_TOKEN="$admin_token" \
        BURROW_RELAY_SIGNING_KEY="$signing_key" \
        BURROW_RELAY_DATA="$registry_file" \
        "$relay_binary" >>"$log_file" 2>&1 &
    local pid=$!
    write_secret "$pid_file" "$pid"
    if ! wait_for_health; then
        kill "$pid" 2>/dev/null || true
        return 1
    fi
}

ensure_host() {
    local host_id host_token admin_token response
    host_id="$(read_secret "$host_id_file" 2>/dev/null || true)"
    host_token="$(read_host_token "$host_id" 2>/dev/null || true)"
    if [[ -n "$host_id" && -n "$host_token" ]]; then
        local status
        status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
            "$relay_url/v1/hosts/$host_id" \
            -H "Authorization: Bearer $host_token" || true)"
        if [[ "$status" == "200" ]]; then
            return
        fi
    fi
    host_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    if [[ "$manages_local_relay" == "1" ]]; then
        admin_token="$(read_secret "$admin_token_file")"
    else
        admin_token="${BURROW_RELAY_ADMIN_TOKEN:-}"
        if [[ -z "$admin_token" ]]; then
            echo "This Host is not registered with $relay_url." >&2
            echo "Set BURROW_RELAY_ADMIN_TOKEN once, then rerun relay:connect." >&2
            exit 64
        fi
    fi
    response="$(curl --fail --silent --show-error \
        -X POST "$relay_url/v1/hosts" \
        -H "Authorization: Bearer $admin_token" \
        -H 'Content-Type: application/json' \
        -d "{\"id\":\"$host_id\",\"name\":\"Local Mac\"}")"
    host_token="$(printf '%s' "$response" | json_field host_credential)"
    write_secret "$host_id_file" "$host_id"
    write_host_token "$host_id" "$host_token"
}

launch_burrow() {
    local host_id host_token
    host_id="$(read_secret "$host_id_file")"
    host_token="$(read_host_token "$host_id")"
    bash "$repository_root/scripts/build-app.sh" debug

    if pgrep -f "$app_executable$" >/dev/null 2>&1; then
        osascript -e 'tell application id "com.abcdlsj.burrow" to quit' >/dev/null 2>&1 || true
        for _ in {1..50}; do
            pgrep -f "$app_executable$" >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi
    if pgrep -f "$app_executable$" >/dev/null 2>&1; then
        echo "Burrow is already running and could not be restarted for credential import." >&2
        exit 1
    fi
    open --env "BURROW_CONTROL_PLANE_URL=$relay_url" \
        --env "BURROW_CONTROL_PLANE_HOST_ID=$host_id" \
        --env "BURROW_CONTROL_PLANE_HOST_TOKEN=$host_token" \
        "$repository_root/Burrow.app"
}

host_is_online() {
    local host_id="$1"
    local host_token="$2"
    local response
    response="$(curl --silent --max-time 1 \
        "$relay_url/v1/hosts/$host_id" \
        -H "Authorization: Bearer $host_token" 2>/dev/null || true)"
    [[ -n "$response" ]] && [[ "$(printf '%s' "$response" | json_field online 2>/dev/null || true)" == "True" ]]
}

wait_for_host() {
    local attempts="${1:-150}"
    local host_id host_token
    host_id="$(read_secret "$host_id_file")"
    host_token="$(read_host_token "$host_id")"
    for ((attempt = 0; attempt < attempts; attempt++)); do
        if host_is_online "$host_id" "$host_token"; then
            return 0
        fi
        sleep 0.1
    done
    echo "Burrow did not connect to Relay. See $log_file" >&2
    return 1
}

pair_host() {
    local host_id host_token pairing_response pairing_code paired_response web_url
    host_id="$(read_secret "$host_id_file")"
    host_token="$(read_host_token "$host_id")"
    pairing_response="$(curl --fail --silent --show-error \
        -X POST "$relay_url/v1/hosts/$host_id/pairing" \
        -H "Authorization: Bearer $host_token")"
    pairing_code="$(printf '%s' "$pairing_response" | json_field pairing_code)"
    paired_response="$(curl --fail --silent --show-error \
        -X POST "$relay_url/v1/pair" \
        -H 'Content-Type: application/json' \
        -d "{\"host_id\":\"$host_id\",\"pairing_code\":\"$pairing_code\"}")"
    web_url="$(printf '%s' "$paired_response" | json_field web_url)"
    echo "Burrow Remote is ready:"
    echo "$web_url"
    if [[ "${BURROW_RELAY_NO_OPEN:-0}" != "1" ]]; then
        open "$web_url"
    fi
}

show_status() {
    wait_for_health
    local host_id host_token
    host_id="$(read_secret "$host_id_file" 2>/dev/null || true)"
    host_token="$(read_host_token "$host_id" 2>/dev/null || true)"
    echo "Relay: healthy at $relay_url"
    if [[ -n "$host_id" && -n "$host_token" ]]; then
        curl --fail --silent --show-error \
            "$relay_url/v1/hosts/$host_id" \
            -H "Authorization: Bearer $host_token" | /usr/bin/python3 -m json.tool
    else
        echo "Host: not registered"
    fi
}

stop_relay() {
    if [[ "$manages_local_relay" != "1" ]]; then
        echo "Refusing to stop externally deployed Relay $relay_url." >&2
        exit 64
    fi
    local pid
    if ! pid="$(relay_pid)" || ! relay_is_running; then
        echo "Relay is not running."
        return
    fi
    kill "$pid"
    for _ in {1..50}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "Relay did not stop cleanly (pid $pid)." >&2
        exit 1
    fi
    echo "Relay stopped. Burrow and tmux sessions were left running."
}

require_command curl
require_command /usr/bin/python3
require_command /usr/sbin/lsof
require_command ps

case "$command_name" in
    up)
        require_command uuidgen
        if [[ "$manages_local_relay" == "1" ]]; then
            require_command go
            require_command openssl
        fi
        start_relay
        ensure_host
        if ! wait_for_host 20 >/dev/null 2>&1; then
            launch_burrow
            wait_for_host
        fi
        pair_host
        ;;
    start)
        if [[ "$manages_local_relay" == "1" ]]; then
            require_command go
            require_command openssl
        fi
        start_relay
        echo "Relay is healthy at $relay_url"
        ;;
    pair)
        pair_host
        ;;
    status)
        show_status
        ;;
    stop)
        stop_relay
        ;;
    logs)
        if [[ "$manages_local_relay" != "1" ]]; then
            echo "External Relay logs are managed by its deployment platform." >&2
            exit 64
        fi
        prepare_state
        touch "$log_file"
        tail -f "$log_file"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
