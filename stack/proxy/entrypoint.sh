#!/bin/bash
set -e

ADDONS_DIR="${ADDONS_DIR:-/addons}"
args=()

while IFS= read -r f; do
    args+=(-s "$f")
done < <(find "$ADDONS_DIR" -maxdepth 1 -name '*.py' | sort)

exec mitmdump \
    --listen-host 0.0.0.0 \
    --listen-port 8080 \
    --set confdir=/home/mitmproxy/.mitmproxy \
    "${args[@]}"
