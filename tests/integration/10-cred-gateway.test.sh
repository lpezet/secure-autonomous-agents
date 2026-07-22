#!/usr/bin/env bash
# cred-gateway: the whitelist boundary between the dev container and the broker.
#
# Runs the real image against a stub broker that answers every path with
# "BROKER-HIT <uri>", so each assertion distinguishes "reached the broker" from
# "denied by the gateway" with no real credentials involved.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-cred-gateway"
build_image "$IMG" stack/cred-gateway || exit 1

CC_SNIPPETS="$REPO_ROOT/examples/claude-code/gateway.d"
DC_SNIPPETS="$REPO_ROOT/examples/dev-container/.devcontainer/gateway.d"

# nginx resolves static proxy_pass upstreams at config-parse time, so a
# standalone `nginx -t` needs `broker` to resolve or it fails before it ever
# reports a syntax error.
nginx_t() {
  docker run --rm --add-host broker:127.0.0.1 \
    ${1:+-v "$1:/etc/nginx/gateway.d:ro"} "$IMG" nginx -t 2>&1
}

suite "config validity"
out=$(nginx_t "")
check_contains "unmounted image passes nginx -t (empty glob is not an error)" "$out" "test is successful"

for d in "$CC_SNIPPETS" "$DC_SNIPPETS" "$FIXTURES/snippets/ok-extra"; do
  out=$(nginx_t "$d")
  check_contains "$(basename "$(dirname "$d")")/$(basename "$d") passes nginx -t" "$out" "test is successful"
done

out=$(nginx_t "$FIXTURES/snippets/bad-zone")
check_contains "redeclaring limit_req_zone in a snippet is rejected" "$out" "is not allowed here"

suite "routing and denial"
net_up
curl_up
stub_broker_up

GW="$RUN_ID-gw"
docker run -d --name "$GW" --network "$NET" -v "$CC_SNIPPETS:/etc/nginx/gateway.d:ro" "$IMG" >/dev/null
track_container "$GW"
wait_http "$GW/healthz" 200 "cred-gateway"

check "GET /healthz" "200" "$(http_code "http://$GW/healthz")"
check_contains "/healthz body" "$(http_body "http://$GW/healthz")" "ok"

# Whitelisted: these two exist because git needs the credential locally.
for p in /github/credential /github/identity; do
  check "GET $p is whitelisted" "200" "$(http_code "http://$GW$p")"
  check_contains "$p reaches the broker" "$(http_body "http://$GW$p")" "BROKER-HIT $p"
done

# Denied: exposing any of these lets dev exfiltrate a usable secret.
for p in /github/token /anthropic/key /anthropic/cred /cloudflare/token /cloudflare/token?profile=x; do
  check "GET $p is denied" "403" "$(http_code "http://$GW$p")"
done
check_not_contains "denied paths never reach the broker" \
  "$(http_body "http://$GW/github/token")" "BROKER-HIT"

# Unknown paths hit the default-deny.
for p in / /admin /github /github/ /broker; do
  check "GET $p falls through to default-deny" "403" "$(http_code "http://$GW$p")"
done

suite "path normalisation cannot escape the whitelist"
# nginx normalises the URI before matching, so these must not smuggle a
# denied path in behind a whitelisted prefix.
for p in "/github/credential/../token" "/github/token/" "//github/token" \
         "/github/./token" "/github%2ftoken" "/GitHub/Token"; do
  check "GET $p is denied" "403" "$(http_code "http://$GW$p")"
done
# Trailing-dot and case variants of an allowed path must not be smuggled either
# — exact match means exact.
check "GET /github/credential/ (trailing slash) is denied" "403" \
  "$(http_code "http://$GW/github/credential/")"
check "GET /GITHUB/CREDENTIAL is denied (locations are case-sensitive)" "403" \
  "$(http_code "http://$GW/GITHUB/CREDENTIAL")"

suite "rate limiting"
# 10r/m with burst=5 nodelay → 6 through, then 503. Guards that a snippet can
# reference the http-level `creds` zone, and that someone who strips
# limit_req from a snippet gets caught.
#
# Needs its own container: the zone keys on $binary_remote_addr and refills at
# 1 request per 6s, so the requests made above have already eaten most of the
# budget for this client. A fresh container starts with an empty zone.
GWRL="$RUN_ID-gwrl"
docker run -d --name "$GWRL" --network "$NET" -v "$CC_SNIPPETS:/etc/nginx/gateway.d:ro" "$IMG" >/dev/null
track_container "$GWRL"
wait_http "$GWRL/healthz" 200 "cred-gateway (rate-limit)"   # /healthz is not rate-limited
codes=$(for i in $(seq 1 10); do http_code "http://$GWRL/github/credential"; printf ' '; done)
n200=$(printf '%s' "$codes" | tr ' ' '\n' | grep -c '^200$' || true)
n503=$(printf '%s' "$codes" | tr ' ' '\n' | grep -c '^503$' || true)
check "6 of 10 rapid requests pass (burst 5 + 1)" "6" "$n200"
check "remaining 4 are rate-limited" "4" "$n503"

suite "multiple snippets compose"
# Adding a provider must not require touching the image.
GW2="$RUN_ID-gw2"
COMBINED="$RUN_ID-combined"
mkdir -p "/tmp/$COMBINED"
cp "$CC_SNIPPETS"/*.conf "$FIXTURES/snippets/ok-extra"/*.conf "/tmp/$COMBINED/"
docker run -d --name "$GW2" --network "$NET" -v "/tmp/$COMBINED:/etc/nginx/gateway.d:ro" "$IMG" >/dev/null
track_container "$GW2"
if wait_http "$GW2/healthz" 200 "cred-gateway (combined snippets)"; then
  check "original snippet still served" "200" "$(http_code "http://$GW2/github/credential")"
  check "added snippet served without an image rebuild" "200" "$(http_code "http://$GW2/extra/credential")"
  check "default-deny still applies" "403" "$(http_code "http://$GW2/github/token")"
else
  ko "combined snippets container did not start" "$(docker logs "$GW2" 2>&1 | tail -5)"
fi
rm -rf "/tmp/$COMBINED"

suite "prefix-match hazard is real"
# Documents WHY gateway.d/README.md mandates `location = /exact/path`.
# If nginx semantics ever changed so this no longer leaked, the rule's
# rationale would need revisiting — so assert the leak explicitly.
GW3="$RUN_ID-gw3"
docker run -d --name "$GW3" --network "$NET" \
  -v "$FIXTURES/snippets/bad-prefix:/etc/nginx/gateway.d:ro" "$IMG" >/dev/null
track_container "$GW3"
if wait_http "$GW3/github/token" 200 "cred-gateway (prefix-match fixture)"; then
  check_contains "a prefix-match snippet leaks /github/token" \
    "$(http_body "http://$GW3/github/token")" "BROKER-HIT /github/token"
else
  ko "prefix-match fixture did not start" "$(docker logs "$GW3" 2>&1 | tail -5)"
fi

suite "gateway cannot be reconfigured at runtime"
# nginx.conf is baked in; only gateway.d is mounted, and read-only.
# The failure message comes from the shell, not from echo, so the redirect has
# to be on `docker exec` itself.
out=$(docker exec "$GW" sh -c 'echo x >> /etc/nginx/gateway.d/github.conf' 2>&1 || true)
check_contains "mounted snippets are read-only inside the container" "$out" "Read-only file system"

finish
