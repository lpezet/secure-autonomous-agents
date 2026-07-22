#!/usr/bin/env bash
# broker: provider auto-discovery and routing. Uses fixture providers rather
# than the real ones, so no credentials are needed and the test does not make
# outbound calls to GitHub or Cloudflare.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-broker"
build_image "$IMG" stack/broker || exit 1

net_up
curl_up

BK="$RUN_ID-broker"
docker run -d --name "$BK" --network "$NET" \
  -v "$FIXTURES/providers:/app/providers:ro" "$IMG" >/dev/null
track_container "$BK"

if ! wait_http "$BK:8080/healthz" 200 "broker"; then
  ko "broker did not start" "$(docker logs "$BK" 2>&1 | tail -20)"
  finish
fi

suite "health and routing"
check "GET /healthz" "200" "$(http_code "http://$BK:8080/healthz")"
check_contains "/healthz body" "$(http_body "http://$BK:8080/healthz")" '"ok":true'
check "unknown route is 404" "404" "$(http_code "http://$BK:8080/nope")"

suite "provider auto-discovery"
# server.js globs *.js from PROVIDERS_DIR at startup — dropping in a file is
# all it takes to add a provider.
check "fixture provider route is served" "200" "$(http_code "http://$BK:8080/echo/ping")"
check_contains "fixture provider response" "$(http_body "http://$BK:8080/echo/ping")" '"pong":true'
check_contains "query string reaches the handler" \
  "$(http_body "http://$BK:8080/echo/query?v=hello")" '"got":"hello"'
check_contains "loaded providers are logged at startup" \
  "$(docker logs "$BK" 2>&1)" "providers loaded: echo.js"
check_not_contains "non-.js files are ignored" \
  "$(docker logs "$BK" 2>&1)" "ignored.txt"

suite "real providers are not baked into the image"
# providers/ is bind-mounted; if it were COPY'd in, a stale credential handler
# could ship inside the image.
out=$(docker run --rm --entrypoint sh "$IMG" -c 'ls /app/providers 2>&1' || true)
check_contains "image has no providers directory of its own" "$out" "No such file"

suite "broker runs unprivileged"
check "container user is not root" "node" "$(docker exec "$BK" whoami 2>/dev/null)"

finish
