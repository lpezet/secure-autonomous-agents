#!/usr/bin/env bash
# Helpers for the e2e tier. Source this instead of ../lib.sh — it pulls lib.sh
# in and adds the bits specific to driving a running compose stack.
#
# The stack is already up by the time a suite runs (tests/e2e/run.sh brings it
# up and tears it down), so suites here create no docker resources of their own
# and lib.sh's EXIT trap has nothing to clean.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE=(docker compose -f "$E2E_DIR/compose.yaml")

# Credential shapes, for check_no_secret. Matching the shape rather than the
# value means a suite never has to hold the secret it is asserting about.
SECRET_PATTERNS=(
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'gh[psuor]_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'v1\.[0-9a-f]{40,}'          # GitHub App installation token
)

# dev <cmd...> — run a command in the dev container. Non-interactive, stderr
# folded in, never fails the calling shell: assertions decide what a failure is.
dev() { "${COMPOSE[@]}" exec -T dev "$@" 2>&1; }

# dev_sh <script> — same, through bash -c.
dev_sh() { "${COMPOSE[@]}" exec -T dev bash -c "$1" 2>&1; }

# dev_code <url> [curl-args...] — HTTP status of a request made from dev.
dev_code() {
  local url="$1"; shift
  "${COMPOSE[@]}" exec -T dev curl -s -o /dev/null -w '%{http_code}' \
    --max-time 30 "$@" "$url" 2>/dev/null
}

# dev_body <url> [curl-args...] — response body of a request made from dev.
dev_body() {
  local url="$1"; shift
  "${COMPOSE[@]}" exec -T dev curl -s --max-time 30 "$@" "$url" 2>/dev/null
}

# svc_logs <service> — recent logs, for failure detail.
svc_logs() { "${COMPOSE[@]}" logs --tail 30 "$1" 2>&1; }
