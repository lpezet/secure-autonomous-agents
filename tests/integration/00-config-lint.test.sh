#!/usr/bin/env bash
# Static checks on committed config. No docker, no network — runs in ~1s.
# These guard invariants documented in CLAUDE.md that are easy to break in a
# hurry and expensive to notice: a prefix-match location, a real credential
# pasted into a compose file, an addon widened to match github.com.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

SNIPPETS=(examples/claude-code/gateway.d/*.conf examples/dev-container/.devcontainer/gateway.d/*.conf)
COMPOSES=(stack/compose.yaml examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml)

suite "cred-gateway snippets use exact-match locations"
# A prefix match like `location /github/` exposes every broker route under it,
# including /github/token. tests/integration/10 proves that leak is real.
for f in "${SNIPPETS[@]}"; do
  bad=$(grep -nE '^[[:space:]]*location[[:space:]]+[^=]' "$f" || true)
  if [ -z "$bad" ]; then ok "$f — all locations exact-match"
  else ko "$f — non-exact location" "$bad"; fi
done

suite "snippets do not expose raw-credential endpoints"
# These hand the dev container a usable secret rather than spending it on
# dev's behalf. They belong in a proxy addon, never in the gateway.
for f in "${SNIPPETS[@]}"; do
  for path in /github/token /anthropic/key /anthropic/cred /cloudflare/token; do
    if grep -q "location[[:space:]]*=[[:space:]]*$path\b" "$f"; then
      ko "$f — exposes $path" "raw credential reachable from dev"
    else
      ok "$f — does not expose $path"
    fi
  done
done

suite "snippets do not redeclare the rate-limit zone"
for f in "${SNIPPETS[@]}"; do
  if grep -q 'limit_req_zone' "$f"; then
    ko "$f — redeclares limit_req_zone" "declared at http level in stack/cred-gateway/nginx.conf"
  else
    ok "$f — references the shared creds zone only"
  fi
done

suite "cred-gateway base image ships no provider endpoints"
conf=stack/cred-gateway/nginx.conf
prov=$(grep -nE '^[[:space:]]*location[[:space:]]*=[[:space:]]*/(github|anthropic|cloudflare)' "$conf" || true)
if [ -z "$prov" ]; then ok "base nginx.conf has no provider locations"
else ko "base nginx.conf has provider locations" "$prov"; fi

check_contains "base nginx.conf includes gateway.d" "$(cat $conf)" 'include /etc/nginx/gateway.d/*.conf;'
if grep -qE '^[[:space:]]*location[[:space:]]*/[[:space:]]*\{' "$conf" && grep -q 'return 403' "$conf"; then
  ok "base nginx.conf keeps the default-deny location"
else
  ko "base nginx.conf default-deny missing" "location / { return 403; } is the backstop"
fi

suite "each example mounts its gateway.d read-only"
for c in examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml; do
  if grep -q 'gateway.d:/etc/nginx/gateway.d:ro' "$c"; then
    ok "$c — gateway.d mounted read-only"
  else
    ko "$c — gateway.d mount missing or writable" "snippets are the whitelist; dev must not be able to edit them"
  fi
done

suite "dev-container shadows .devcontainer as read-only"
# This example mounts ../ (the parent of .devcontainer) read-write at
# /workspace, so without the nested mount the agent can rewrite addons/,
# providers/ and gateway.d/ and wait for a restart. tests/integration/50 proves the
# shadow works at runtime.
c=examples/dev-container/.devcontainer/compose.yaml
if grep -q '\.\./\.devcontainer:/workspace/\.devcontainer:ro' "$c"; then
  ok "$c — nested read-only bind present"
else
  ko "$c — nested read-only bind missing" "agent could widen the proxy allowlist or gateway whitelist"
fi

suite "dev containers hold no real credentials"
# CLAUDE.md invariant: these are dummy values that satisfy client-side "am I
# authenticated?" checks. The proxy strips and replaces them at the wire level.
for c in "${COMPOSES[@]}"; do
  for var in GH_TOKEN CLOUDFLARE_API_TOKEN ANTHROPIC_API_KEY; do
    line=$(grep -E "^[[:space:]]*$var:" "$c" || true)
    [ -z "$line" ] && continue
    val=$(printf '%s' "$line" | sed 's/.*: *//' | tr -d '"'"'"' ')
    if [ "$val" = "proxy-injected" ]; then
      ok "$c — $var is the dummy placeholder"
    else
      ko "$c — $var is not 'proxy-injected'" "found: $val"
    fi
  done
done

suite "no credential material committed"
# Length-bounded so `.env.example` placeholders (sk-ant-..., ghp_xxx) do not
# trip the check while a real key still would.
for pat in 'sk-ant-[A-Za-z0-9_-]{20,}' 'ghp_[A-Za-z0-9]{20,}' 'github_pat_[A-Za-z0-9_]{20,}' \
           'BEGIN RSA PRIVATE KEY' 'BEGIN PRIVATE KEY' 'BEGIN OPENSSH PRIVATE KEY'; do
  hits=$(git grep -lE "$pat" -- . ':!tests/integration/00-config-lint.test.sh' 2>/dev/null || true)
  if [ -z "$hits" ]; then ok "no match for /$pat/"
  else ko "credential-shaped string committed: /$pat/" "$hits"; fi
done

suite "github addon does not match github.com"
# Documented invariant: git push/pull authenticates through the credential
# helper. Matching github.com here collides with git's Basic auth handshake
# inside the MITMed tunnel.
for f in examples/*/addons/010_github.py examples/*/.devcontainer/addons/010_github.py; do
  [ -f "$f" ] || continue
  bad=$(grep -nE '"github\.com"|'\''github\.com'\''' "$f" || true)
  if [ -z "$bad" ]; then ok "$f — matches api./uploads. hosts only"
  else ko "$f — matches github.com" "$bad"; fi
done

suite "policy addon loads before provider addons"
# 000_policy.py must run first; entrypoint.sh globs alphabetically.
for d in examples/*/addons examples/*/.devcontainer/addons stack/proxy/addons; do
  [ -d "$d" ] || continue
  first=$(ls "$d"/*.py 2>/dev/null | head -1 | xargs -r basename)
  check "$d — first addon is 000_policy.py" "000_policy.py" "$first"
done

finish
