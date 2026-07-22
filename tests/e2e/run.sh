#!/usr/bin/env bash
# End-to-end tier: the whole stack, real credentials, real vendor APIs.
#
#   tests/run.sh e2e            # via the facade
#   tests/e2e/run.sh            # or directly
#   tests/e2e/run.sh 20         # only suites starting with 20
#   KEEP_STACK=1 tests/e2e/run.sh   # leave the stack up afterwards to poke at
#
# Skips (exit 0) rather than fails when the credentials are not configured, so
# this is safe to wire into a pipeline that does not have them. Run it with no
# setup once and it will tell you exactly what is missing.
#
# This tier spends real API quota and pushes to a real repository. See README.
set -uo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
COMPOSE=(docker compose -f "$E2E_DIR/compose.yaml")

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=''; R=''; Y=''; B=''; N=''
fi

# ------------------------------------------------------------------ preflight

: "${AGENT_CREDS_DIR:=$HOME/.config/agent-creds-e2e}"
export AGENT_CREDS_DIR

skip_tier() {
  printf '\n%se2e skipped%s — %s\n' "$Y" "$N" "$1"
  printf '   setup: %s/README.md\n' "$E2E_DIR"
  exit 0
}

# Refuse to point at the production credential directory. e2e mints tokens,
# pushes commits and burns quota; doing that with the App a real agent depends
# on turns a test bug into a production incident. This is a hard stop, not a
# warning — there is no legitimate reason to aim this tier at those creds.
PROD_CREDS="$HOME/.config/agent-creds"
if [ "$(cd "$AGENT_CREDS_DIR" 2>/dev/null && pwd)" = "$(cd "$PROD_CREDS" 2>/dev/null && pwd)" ] \
   && [ -d "$PROD_CREDS" ]; then
  printf '%srefusing to run%s: AGENT_CREDS_DIR resolves to %s\n' "$R" "$N" "$PROD_CREDS" >&2
  printf 'e2e needs its own GitHub App and its own credential directory.\n' >&2
  exit 2
fi

[ -d "$AGENT_CREDS_DIR" ] || skip_tier "no credential directory at $AGENT_CREDS_DIR"
[ -f "$AGENT_CREDS_DIR/github-app.pem" ] || skip_tier "no github-app.pem in $AGENT_CREDS_DIR"
[ -f "$E2E_DIR/.env" ] || skip_tier "no tests/e2e/.env (copy .env.example and fill it in)"

# shellcheck disable=SC1091
set -a; . "$E2E_DIR/.env"; set +a

for v in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID; do
  [ -n "${!v:-}" ] || skip_tier "$v is empty in tests/e2e/.env"
done
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  skip_tier "set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN in tests/e2e/.env"
fi

if ! docker version >/dev/null 2>&1; then
  printf '%sdocker is unavailable%s — e2e needs it.\n' "$R" "$N" >&2
  exit 2
fi

# ---------------------------------------------------------------- stack up/down

teardown() {
  local rc=$?
  if [ -n "${KEEP_STACK:-}" ]; then
    printf '\n%sKEEP_STACK set%s — stack left running. Tear down with:\n' "$Y" "$N"
    printf '  docker compose -f %s down -v\n' "$E2E_DIR/compose.yaml"
  else
    printf '\n%s── tearing down ──%s\n' "$B" "$N"
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1
  fi
  exit $rc
}
trap teardown EXIT INT TERM

printf '%s── building ──%s\n' "$B" "$N"
# stack/dev is the real base image; tests/e2e/dev extends it with gh. Building
# it here keeps that a reference rather than a copy.
docker build -q -t sat-e2e-devbase "$REPO_ROOT/stack/dev" >/dev/null || {
  printf '%sfailed to build the dev base image%s\n' "$R" "$N" >&2; exit 2; }
"${COMPOSE[@]}" build >/dev/null || {
  printf '%scompose build failed%s\n' "$R" "$N" >&2; exit 2; }

printf '%s── starting stack ──%s\n' "$B" "$N"
if ! "${COMPOSE[@]}" up -d --wait; then
  printf '%sstack did not come up healthy%s\n' "$R" "$N" >&2
  "${COMPOSE[@]}" ps
  "${COMPOSE[@]}" logs --tail 40 broker proxy cred-gateway
  exit 1
fi

# The devcontainer lifecycle scripts do not run here, so do their two essential
# steps by hand: trust the mitmproxy CA and wire the git credential helper.
# Everything downstream (HTTPS through the proxy, git push) depends on these.
printf '%s── preparing dev container ──%s\n' "$B" "$N"
"${COMPOSE[@]}" exec -T dev bash -euo pipefail -c '
  cp /proxy-certs/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
  update-ca-certificates >/dev/null 2>&1
  git config --global credential.helper "!f() { curl -s \"\$GIT_CREDENTIAL_URL\"; }; f"
  git config --global credential.useHttpPath false
  git config --global --add safe.directory "*"
' || { printf '%sdev container preparation failed%s\n' "$R" "$N" >&2; exit 1; }

# ------------------------------------------------------------------- run suites

files=()
if [ $# -gt 0 ]; then
  for pat in "$@"; do
    for f in "$E2E_DIR/$pat"*.test.sh; do [ -f "$f" ] && files+=("$f"); done
  done
else
  for f in "$E2E_DIR"/*.test.sh; do [ -f "$f" ] && files+=("$f"); done
fi
if [ "${#files[@]}" -eq 0 ]; then
  echo "no test files matched" >&2
  exit 2
fi

failed=()
started=$SECONDS
for f in "${files[@]}"; do
  name="$(basename "$f" .test.sh)"
  printf '\n%s┏━ %s %s\n' "$B" "$name" "$N"
  if bash "$f"; then
    printf '%s┗━ %s ok%s\n' "$G" "$name" "$N"
  else
    rc=$?
    printf '%s┗━ %s FAILED (exit %d)%s\n' "$R" "$name" "$rc" "$N"
    failed+=("$name")
  fi
done

elapsed=$((SECONDS - started))
printf '\n%s────────────────────────────%s\n' "$B" "$N"
printf 'ran %d suite(s) in %ds\n' "${#files[@]}" "$elapsed"

if [ "${#failed[@]}" -gt 0 ]; then
  printf '%sfailed: %s%s\n' "$R" "${failed[*]}" "$N"
  exit 1
fi
printf '%sall suites passed%s\n' "$G" "$N"
