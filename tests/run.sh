#!/usr/bin/env bash
# Facade over the test tiers. Dispatches to tests/<tier>/run.sh, passing every
# remaining argument (and the whole environment) through untouched.
#
#   tests/run.sh                     # integration — the safe default
#   tests/run.sh integration 20 30   # → tests/integration/run.sh 20 30
#   tests/run.sh e2e                 # → tests/e2e/run.sh
#   tests/run.sh all                 # both, integration first
#
# A bare `tests/run.sh` deliberately does NOT run e2e. That tier spends real
# API quota, mints real tokens and pushes to a real repository, so it has to be
# something you asked for by name rather than something the obvious command
# does to you.
#
# `all` is fail-fast: if integration is red there is no point paying for e2e,
# and its failures would most likely be downstream noise anyway.
#
# Exit code is non-zero if any tier fails. Tiers print their own summaries;
# this script aggregates exit codes only.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIERS=(integration e2e)

if [ -t 1 ]; then
  R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
else
  R=''; B=''; N=''
fi

usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
  exit "${1:-0}"
}

# First argument selects the tier, but only if it names one. Anything else is
# left alone so `tests/run.sh 20` still means "integration, suite 20" — the
# shorthand that existed before this facade did.
selected=(integration)
case "${1-}" in
  integration|e2e) selected=("$1"); shift ;;
  all)             selected=("${TIERS[@]}"); shift ;;
  -h|--help)       usage 0 ;;
esac

run_tier() { # run_tier <name> [args...]
  local tier="$1"; shift
  local script="$TESTS_DIR/$tier/run.sh"
  if [ ! -x "$script" ] && [ ! -f "$script" ]; then
    printf '%sno such tier: %s%s (expected %s)\n' "$R" "$tier" "$N" "$script" >&2
    return 2
  fi
  printf '\n%s╔══ %s ══╗%s\n' "$B" "$tier" "$N"
  bash "$script" "$@"
}

failed=()
for tier in "${selected[@]}"; do
  if ! run_tier "$tier" "$@"; then
    failed+=("$tier")
    # Fail fast: never spend real credentials to re-discover a failure the
    # free tier already found.
    [ "${#selected[@]}" -gt 1 ] && break
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  printf '\n%stier(s) failed: %s%s\n' "$R" "${failed[*]}" "$N" >&2
  exit 1
fi
