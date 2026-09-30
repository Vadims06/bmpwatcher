#!/usr/bin/env bash
# Configures and starts BMP Watcher from its registration in Topolograph:
# the answers from the Add watcher wizard come back with the watcher token.
set -euo pipefail

usage() {
    echo "Usage: sudo ./configure.sh --url <topolograph-url> --token <watcher-token>" >&2
    exit 2
}

url=""
token=""
while [ $# -gt 0 ]; do
    case "$1" in
        --url) url="${2:-}"; shift 2 ;;
        --token) token="${2:-}"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$url" ] && [ -n "$token" ] || usage
cd "$(dirname "$0")"

missing=()
command -v docker >/dev/null 2>&1 || missing+=("docker")
docker compose version >/dev/null 2>&1 || missing+=("docker compose v2")
command -v curl >/dev/null 2>&1 || missing+=("curl")
command -v git >/dev/null 2>&1 || missing+=("git")
[ "$(id -u)" -eq 0 ] || missing+=("root: run with sudo")
if [ ${#missing[@]} -gt 0 ]; then
    echo "Install or fix first: ${missing[*]}" >&2
    exit 1
fi

host_id=$(cat /etc/machine-id 2>/dev/null || hostname)
ref=$(git describe --tags --exact-match 2>/dev/null || git symbolic-ref -q --short HEAD 2>/dev/null || git rev-parse --short HEAD)
answer=$(mktemp)
trap 'rm -f "$answer"' EXIT

echo "Fetching the watcher configuration from ${url%/}"
if ! status=$(curl -sS -G -o "$answer" -w '%{http_code}' \
        -H "Authorization: Bearer $token" \
        --data-urlencode "host_id=$host_id" \
        --data-urlencode "host_name=$(hostname)" \
        --data-urlencode "ref=$ref" \
        --data-urlencode "format=env" \
        "${url%/}/api/watcher/config"); then
    echo "Cannot reach Topolograph at $url" >&2
    exit 1
fi
if [ "$status" != "200" ]; then
    echo "Topolograph answered $status: $(cat "$answer")" >&2
    exit 1
fi

{
    echo "# Written by configure.sh from the watcher registration in Topolograph."
    echo "# Change answers on the watcher page and run configure.sh again."
    cat "$answer"
    echo "WATCHER_VERSION='$(cat VERSION)'"
} > .env
chmod 600 .env

value() { grep "^$1=" .env | cut -d"'" -f2; }
mkdir -p "$(value BMPWATCHER_LOG_DIR)"
docker compose --profile collector up -d

echo
echo "BMP Watcher $(value WATCHER_NAME) is running."
echo "Point BMP on your routers to this host, TCP port $(value BMP_PORT), and follow the status in Topolograph."
