#!/usr/bin/env bash
# git over HTTPS through the credential helper.
#
# The single most under-tested path in the repo, and the one the cred-gateway
# refactor moved. Nothing else exercises it: 010_github.py deliberately does
# NOT match github.com, so a push authenticates via `git credential` →
# cred-gateway → broker, entirely outside token injection. If that path breaks,
# every other test still passes and the agent simply cannot push.
#
# Needs E2E_TEST_REPO (owner/repo) — a throwaway repository the e2e GitHub App
# is installed on. Skips without it. Pushes a scratch branch and deletes it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

REPO="${E2E_TEST_REPO:-}"

suite "git identity comes from the broker"
ident=$(dev_body "http://cred-gateway/github/identity")
name=$(printf '%s' "$ident" | jq -r '.name // empty' 2>/dev/null)
email=$(printf '%s' "$ident" | jq -r '.email // empty' 2>/dev/null)
if [ -n "$name" ] && [ -n "$email" ]; then
  ok "identity endpoint returns a name and email"
  check_contains "email is a GitHub App identity" "$email" "users.noreply.github.com"
else
  ko "identity endpoint returned nothing usable" "$(printf '%s' "$ident" | head -c 200)"
fi

if [ -z "$REPO" ]; then
  suite "clone and push"
  skip "clone and push" "set E2E_TEST_REPO=owner/repo in tests/e2e/.env"
  finish
fi
if [ -z "$name" ] || [ -z "$email" ]; then
  suite "clone and push"
  skip "clone and push" "no App identity, so the commit would be misattributed"
  finish
fi

BRANCH="e2e-$(date +%Y%m%d-%H%M%S)-$$"

# Always try to remove the remote branch, even if the push assertion failed
# partway. Uses the same credential path as the push itself.
cleanup_branch() {
  dev_sh "cd /tmp/e2e-clone 2>/dev/null && git push origin --delete '$BRANCH' >/dev/null 2>&1 || true" >/dev/null
}
# Chained, not replaced: lib.sh installs its own EXIT trap and a bare
# `trap ... EXIT` here would silently drop it.
trap 'cleanup_branch; cleanup' EXIT

suite "clone over HTTPS via the credential helper"
out=$(dev_sh "rm -rf /tmp/e2e-clone && git clone --depth 1 https://github.com/$REPO /tmp/e2e-clone 2>&1")
if dev_sh 'test -d /tmp/e2e-clone/.git && echo yes' | grep -q yes; then
  ok "clone succeeded"
else
  ko "clone failed" "$(printf '%s' "$out" | head -c 400)"
  finish
fi

# The helper is invoked per-operation and its output is consumed by git on a
# pipe. Nothing should have persisted the token into the clone.
cfg=$(dev_sh 'cat /tmp/e2e-clone/.git/config 2>/dev/null || true')
check_no_secret "no token written into .git/config" "$cfg" "${SECRET_PATTERNS[@]}"
check_not_contains "remote URL carries no inline credentials" "$cfg" "@github.com"

suite "commit and push as the App identity"
out=$(dev_sh "cd /tmp/e2e-clone \
  && git config user.name '$name' \
  && git config user.email '$email' \
  && git checkout -q -b '$BRANCH' \
  && git commit -q --allow-empty -m 'e2e: credential helper smoke test' \
  && git push -q origin '$BRANCH' 2>&1 && echo PUSH-OK")
check_contains "push succeeded through the credential helper" "$out" "PUSH-OK"

# Confirm from the other side, through the injection path rather than the
# helper path — so this also cross-checks that the two agree on identity.
if printf '%s' "$out" | grep -q PUSH-OK; then
  remote=$(dev_sh "gh api repos/$REPO/branches/$BRANCH --jq .name 2>/dev/null")
  check "branch exists on the remote" "$BRANCH" "$remote"

  author=$(dev_sh "cd /tmp/e2e-clone && git log -1 --format=%ae")
  check "commit is authored by the App identity" "$email" "$author"
fi

suite "cleanup"
cleanup_branch
gone=$(dev_sh "gh api repos/$REPO/branches/$BRANCH >/dev/null 2>&1 && echo STILL-THERE || echo gone")
check "scratch branch removed" "gone" "$gone"
dev_sh 'rm -rf /tmp/e2e-clone' >/dev/null

finish
