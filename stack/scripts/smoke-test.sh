#!/bin/bash
# Smoke test for the credential broker + proxy setup.
# Run inside the dev container.

set -euo pipefail

section() {
  echo
  echo "=========================================="
  echo "  $1"
  echo "=========================================="
}

# ---------- Network isolation (security boundary) ----------
section "1. Broker is NOT directly reachable from dev"
if curl -s --max-time 2 http://broker:8080/healthz > /dev/null 2>&1; then
  echo "FAIL: broker reachable — security boundary broken"
  exit 1
else
  echo "PASS: broker unreachable from dev container"
fi

section "1b. Broker is NOT reachable via proxy tunnel (policy.py)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --proxy http://proxy:8080 http://broker:8080/healthz)
echo "HTTP $HTTP_CODE (expected 403)"
[ "$HTTP_CODE" = "403" ] || { echo "FAIL: proxy forwarded request to broker"; exit 1; }
echo "PASS: proxy blocked tunnel to broker"

section "2. cred-gateway exposes only whitelisted endpoints"
echo "  /healthz (allowed):"
curl -sf http://cred-gateway/healthz
echo "  /github/credential (allowed):"
curl -sf http://cred-gateway/github/credential | head -1
echo "  /anthropic/key (DENIED):"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://cred-gateway/anthropic/key)
echo "    HTTP $HTTP_CODE (expected 403)"
[ "$HTTP_CODE" = "403" ] || { echo "FAIL: gateway leaked /anthropic/key"; exit 1; }
echo "  /github/token (DENIED — only /github/credential is whitelisted):"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://cred-gateway/github/token)
echo "    HTTP $HTTP_CODE (expected 403)"
[ "$HTTP_CODE" = "403" ] || { echo "FAIL: gateway leaked /github/token"; exit 1; }

# ---------- Proxy interception ----------
section "3. Anthropic API call via proxy (no API key in env)"
echo "ANTHROPIC_API_KEY is: ${ANTHROPIC_API_KEY:-<not set, as expected>}"
curl -sf https://api.anthropic.com/v1/messages \
  -H "content-type: application/json" \
  -d '{
    "model": "claude-haiku-4-5",
    "max_tokens": 50,
    "messages": [{"role": "user", "content": "Reply with just the word PONG"}]
  }' | jq -r '.content[0].text'

section "4. Anthropic streaming via proxy (verifies SSE passthrough)"
curl -N -sf https://api.anthropic.com/v1/messages \
  -H "content-type: application/json" \
  -d '{
    "model": "claude-haiku-4-5",
    "max_tokens": 50,
    "stream": true,
    "messages": [{"role": "user", "content": "Count 1 to 5"}]
  }' | head -20

section "5. Anthropic Admin API is BLOCKED by proxy policy"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://api.anthropic.com/v1/organizations/api_keys)
echo "HTTP $HTTP_CODE (expected 403)"
[ "$HTTP_CODE" = "403" ] || { echo "FAIL: Admin API not blocked"; exit 1; }

# ---------- GitHub via proxy (using GH_TOKEN=proxy-injected dummy) ----------
section "6. GitHub API via proxy (dummy GH_TOKEN, real token injected by proxy)"
# /user requires a user OAuth token; installation tokens act as the App, not a user.
# /installation/repositories is the canonical endpoint for installation tokens.
gh api /installation/repositories | jq '{total_count, repos: [.repositories[].full_name]}'

section "7. GitHub API rate limit (verify it's the App's quota)"
gh api /rate_limit | jq '.rate'

# ---------- Git via cred-gateway ----------
section "8. Git clone via credential helper (uncomment to test on a real repo)"
# TMPDIR=$(mktemp -d) && cd "$TMPDIR"
# git clone https://github.com/YOUR_ORG/YOUR_PRIVATE_REPO.git

# ---------- Cloudflare via proxy ----------
# Note: wrangler's handling of CLOUDFLARE_API_TOKEN=proxy-injected is
# version-dependent. If wrangler validates the token format client-side
# before making any network call, it may reject the dummy value before
# the proxy can replace it. Test with your installed wrangler version.
section "9. Cloudflare via proxy (uncomment if Cloudflare configured)"
# wrangler whoami

section "All checks passed."
