#!/usr/bin/env bash
# proxy 001_allowlist.py: egress control. Absent file → permissive (documented
# behaviour, so the stack works before anyone writes an allowlist). Present
# file → default-deny with per-domain method restrictions.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-proxy"
build_image "$IMG" stack/proxy || exit 1

net_up
curl_up
stub_broker_up readonly-api write-api anything-api foo.cdn.test other-api

# start_proxy <outvar> <name> [allowlist-file]
# Sets <outvar> to the container name; returns non-zero if it never came up.
# Must NOT be called in a command substitution: track_container has to run in
# this shell or the EXIT trap never sees the container and it leaks.
start_proxy() {
  local outvar="$1" name="$RUN_ID-$2"; shift 2
  local mount=()
  [ $# -gt 0 ] && mount=(-v "$1:/etc/agent-allowlist:ro")
  printf -v "$outvar" '%s' "$name"
  docker run -d --name "$name" --network "$NET" \
    -v "$REPO_ROOT/stack/proxy/addons:/addons:ro" \
    "${mount[@]}" -e BROKER_URL=http://broker:8080 -e PYTHONUNBUFFERED=1 \
    "$IMG" >/dev/null
  track_container "$name"
  local i code
  for i in $(seq 1 60); do
    code=$(http_code "http://readonly-api:8080/ping" --proxy "http://$name:8080")
    [ -n "$code" ] && [ "$code" != "000" ] && return 0
    sleep 0.5
  done
  return 1
}

suite "no allowlist file → permissive (documented default)"
if start_proxy PX permissive; then
  check "unlisted destination allowed" "200" \
    "$(http_code "http://other-api:8080/ping" --proxy "http://$PX:8080")"
  check "POST to unlisted destination allowed" "200" \
    "$(http_code "http://other-api:8080/ping" -X POST --proxy "http://$PX:8080")"
else
  ko "permissive proxy did not start" "$(docker logs "$PX" 2>&1 | tail -20)"
fi

suite "allowlist file present → default-deny"
if start_proxy PXA enforcing "$FIXTURES/allowlist"; then
  P="--proxy http://$PXA:8080"

  check "unlisted domain blocked" "403" "$(http_code "http://other-api:8080/ping" $P)"
  check_contains "block cites the allowlist" \
    "$(http_body "http://other-api:8080/ping" $P)" "blocked by allowlist"

  # `readonly-api` carries a trailing `# comment` and no method column, so it
  # must fall back to GET,HEAD,OPTIONS. Before inline comments were stripped,
  # "# trailing comment; defaults to get,head,options" was parsed as the method
  # list and blocked everything — fail-closed, but silent and hard to debug.
  check "trailing comment does not become the method list" "200" \
    "$(http_code "http://readonly-api:8080/ping" $P)"
  check "listed domain, default methods: GET allowed" "200" \
    "$(http_code "http://readonly-api:8080/ping" $P)"
  check "listed domain, default methods: POST blocked" "403" \
    "$(http_code "http://readonly-api:8080/ping" -X POST $P)"
  check "listed domain, default methods: DELETE blocked" "403" \
    "$(http_code "http://readonly-api:8080/ping" -X DELETE $P)"

  # `write-api GET,POST`
  check "explicit methods: GET allowed" "200" \
    "$(http_code "http://write-api:8080/ping" $P)"
  check "explicit methods: POST allowed" "200" \
    "$(http_code "http://write-api:8080/ping" -X POST $P)"
  check "explicit methods: PUT blocked" "403" \
    "$(http_code "http://write-api:8080/ping" -X PUT $P)"

  # `anything-api *`
  for m in GET POST PUT DELETE PATCH; do
    check "wildcard methods: $m allowed" "200" \
      "$(http_code "http://anything-api:8080/ping" -X "$m" $P)"
  done

  # `*.cdn.test GET`
  check "wildcard domain matches subdomain" "200" \
    "$(http_code "http://foo.cdn.test:8080/ping" $P)"
  check "wildcard domain still enforces methods" "403" \
    "$(http_code "http://foo.cdn.test:8080/ping" -X POST $P)"

  # A suffix match must not let `evilcdn.test` through on `*.cdn.test`.
  # The addon compares with endswith(".cdn.test"), so this is a real guard.
  check "wildcard does not match a sibling domain" "403" \
    "$(http_code "http://evilcdn.test:8080/ping" $P)"

  # Internal hosts stay blocked by 000_policy even in permissive method terms.
  check "internal host still blocked when allowlist is active" "403" \
    "$(http_code "http://broker:8080/healthz" $P)"

  # REGRESSION: the addon matched pretty_host, so spoofing the Host header to
  # an allowlisted domain let any destination through — egress control off with
  # one header. It now matches the real destination.
  check "spoofed Host does not smuggle an unlisted destination" "403" \
    "$(http_code "http://other-api:8080/ping" -H "Host: anything-api" $P)"
  check "spoofed Host does not upgrade the permitted method set" "403" \
    "$(http_code "http://readonly-api:8080/ping" -X POST -H "Host: anything-api" $P)"
else
  ko "enforcing proxy did not start" "$(docker logs "$PXA" 2>&1 | tail -20)"
fi

finish
