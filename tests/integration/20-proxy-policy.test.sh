#!/usr/bin/env bash
# proxy 000_policy.py: the dev container must not be able to tunnel to internal
# services through the proxy. Docker network isolation is the primary control;
# this addon is the defence-in-depth layer, and it is the one that is easy to
# break by editing an addon.
#
# Plain HTTP only — testing the HTTPS path would need the generated CA, and the
# policy addon matches on hostname before any TLS decision is made.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-proxy"
build_image "$IMG" stack/proxy || exit 1

net_up
curl_up
# The stub answers to `broker`, `cred-gateway` (blocked names) and
# `external-api` (a stand-in for a legitimate destination).
stub_broker_up cred-gateway external-api

PX="$RUN_ID-proxy"
docker run -d --name "$PX" --network "$NET" \
  -v "$REPO_ROOT/stack/proxy/addons:/addons:ro" \
  -e BROKER_URL=http://broker:8080 -e PYTHONUNBUFFERED=1 \
  "$IMG" >/dev/null
track_container "$PX"

# mitmdump takes a moment to import addons; poll through the proxy itself.
ready=false
for _ in $(seq 1 60); do
  if [ "$(http_code "http://external-api:8080/ping" --proxy "http://$PX:8080")" = "200" ]; then
    ready=true; break
  fi
  sleep 0.5
done

if [ "$ready" != true ]; then
  ko "proxy did not become ready" "$(docker logs "$PX" 2>&1 | tail -20)"
  finish
fi

suite "proxy forwards legitimate destinations"
check "GET external-api through proxy" "200" \
  "$(http_code "http://external-api:8080/ping" --proxy "http://$PX:8080")"
check_contains "response comes from the upstream" \
  "$(http_body "http://external-api:8080/ping" --proxy "http://$PX:8080")" "BROKER-HIT"

suite "proxy blocks internal hostnames (000_policy.py)"
for host in broker cred-gateway; do
  code=$(http_code "http://$host:8080/healthz" --proxy "http://$PX:8080")
  check "CONNECT-less GET to $host is blocked" "403" "$code"
  body=$(http_body "http://$host:8080/healthz" --proxy "http://$PX:8080")
  check_contains "$host block cites the policy addon" "$body" "internal host blocked"
  check_not_contains "$host response never carries upstream content" "$body" "BROKER-HIT"
done

suite "block applies regardless of method or path"
for m in GET POST PUT DELETE; do
  check "$m http://broker:8080/github/token is blocked" "403" \
    "$(http_code "http://broker:8080/github/token" -X "$m" --proxy "http://$PX:8080")"
done

suite "host-header spoofing does not bypass the block"
# REGRESSION: the addon originally matched flow.request.pretty_host, which
# prefers the client-supplied Host header. mitmproxy still connects to
# flow.request.host, so one header turned the proxy into an open door to the
# broker — `-H 'Host: anything'` returned a real /github/token. Both checks
# below failed before the fix.
check "spoofed Host on a broker URL is still blocked" "403" \
  "$(http_code "http://broker:8080/healthz" -H "Host: external-api" --proxy "http://$PX:8080")"
check "spoofed Host cannot reach a credential endpoint" "403" \
  "$(http_code "http://broker:8080/github/token" -H "Host: external-api" --proxy "http://$PX:8080")"
check_not_contains "spoofed request never carries broker content" \
  "$(http_body "http://broker:8080/github/token" -H "Host: external-api" --proxy "http://$PX:8080")" \
  "BROKER-HIT"
check "spoofed Host on cred-gateway is still blocked" "403" \
  "$(http_code "http://cred-gateway:8080/github/credential" -H "Host: external-api" --proxy "http://$PX:8080")"

# The reverse direction fails closed: claiming to be an internal host is denied
# even when the real destination is external. Harmless over-blocking, and it
# keeps the rule easy to reason about.
check "claiming Host: broker is denied even when the target is external" "403" \
  "$(http_code "http://external-api:8080/ping" -H "Host: broker" --proxy "http://$PX:8080")"

finish
