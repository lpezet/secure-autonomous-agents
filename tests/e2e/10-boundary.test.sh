#!/usr/bin/env bash
# The security boundary, against a stack that is actually holding secrets.
#
# tests/integration/ asserts all of this too, but against a stub broker that
# hands out a marker string. Here the broker holds a real GitHub App key and a
# real Anthropic credential, so a hole is a disclosure rather than a failed
# string comparison. Same assertions, real stakes — that is the point of
# running them twice.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

suite "broker is unreachable from dev"
# Not on the `dev` network at all: Docker DNS should not even resolve it.
out=$(dev_sh 'getent hosts broker || echo NXDOMAIN')
check_contains "broker does not resolve from dev" "$out" "NXDOMAIN"

out=$(dev_sh 'curl -s --max-time 3 -o /dev/null -w "%{http_code}" http://broker:8080/healthz --noproxy "*" || echo CONNFAIL')
check_contains "direct connection to broker fails" "$out" "CONNFAIL"

# The proxy bridges `dev` and `secure`, so it is the one path that could reach
# the broker. 000_policy.py has to close it.
check "proxy refuses to tunnel to broker" "403" \
  "$(dev_code "http://broker:8080/github/token" --proxy http://proxy:8080)"
check "proxy refuses to tunnel to broker with a spoofed Host" "403" \
  "$(dev_code "http://broker:8080/github/token" --proxy http://proxy:8080 -H "Host: api.github.com")"
check "proxy refuses to tunnel to cred-gateway" "403" \
  "$(dev_code "http://cred-gateway/github/token" --proxy http://proxy:8080)"

suite "cred-gateway exposes only the whitelisted endpoints"
check "/healthz reachable" "200" "$(dev_code "http://cred-gateway/healthz")"

# Not-403 rather than 200: this suite is about what the whitelist permits, and
# these paths proxy to the broker. A broker that cannot mint a token answers
# 500, which is a broker problem — it must not read as "the whitelist is
# broken". Whether the endpoints return anything usable is asserted below,
# where the broker is the subject.
check_ne "/github/credential is not denied" "403" \
  "$(dev_code "http://cred-gateway/github/credential")"
check_ne "/github/identity is not denied" "403" \
  "$(dev_code "http://cred-gateway/github/identity")"

for path in /github/token /anthropic/key /anthropic/cred /cloudflare/token /healthz/../github/token; do
  check "$path denied" "403" "$(dev_code "http://cred-gateway$path")"
done

suite "the endpoints that are allowed return something real"
# Failures here mean the broker could not mint — bad App id, wrong private key,
# App not installed — not that the boundary leaked. Check `docker compose
# logs broker` first.
#
# Deliberately assertion-by-shape: the body holds a live installation token,
# which dev is entitled to (git needs it locally) but the terminal is not.
have() { dev_sh "curl -s http://cred-gateway$1 | grep -cE '$2' || true"; }

check "/github/credential returns 200" "200" \
  "$(dev_code "http://cred-gateway/github/credential")"
check "/github/identity returns 200" "200" \
  "$(dev_code "http://cred-gateway/github/identity")"

check "credential helper output is in git credential format" "1" "$(have /github/credential '^password=.+')"
check "credential helper returns a username" "1" "$(have /github/credential '^username=.+')"
check "identity returns a name" "1" "$(have /github/identity '\"name\"')"
check "identity returns an email" "1" "$(have /github/identity '\"email\"')"

suite "dev holds no raw vendor credential"
# The dummy values must survive: if either of these is a real key, the whole
# design has been bypassed somewhere.
check "ANTHROPIC_API_KEY is still the placeholder" "proxy-injected" \
  "$(dev_sh 'printf %s "$ANTHROPIC_API_KEY"')"
check "GH_TOKEN is still the placeholder" "proxy-injected" \
  "$(dev_sh 'printf %s "$GH_TOKEN"')"

# Nothing under the dev container's home should look like a vendor secret.
# The installation token is fetched per-invocation by the credential helper and
# never written to disk, so a match here means something cached it.
env_dump=$(dev_sh 'env' )
check_no_secret "no credential-shaped value in dev's environment" "$env_dump" "${SECRET_PATTERNS[@]}"

git_cfg=$(dev_sh 'cat ~/.gitconfig 2>/dev/null || true')
check_no_secret "no credential-shaped value in ~/.gitconfig" "$git_cfg" "${SECRET_PATTERNS[@]}"

finish
