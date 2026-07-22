#!/usr/bin/env bash
# Regression suite runner.
#
#   tests/run.sh              # everything
#   tests/run.sh 00 10        # only suites whose filename starts with 00 or 10
#   FORCE_BUILD=1 tests/run.sh   # rebuild images instead of reusing cached ones
#
# Exit code is non-zero if any suite fails. No credentials are required: every
# suite runs against stubs and fixtures.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=''; R=''; B=''; N=''
fi

files=()
if [ $# -gt 0 ]; then
  for pat in "$@"; do
    for f in "$TESTS_DIR/$pat"*.test.sh; do [ -f "$f" ] && files+=("$f"); done
  done
else
  for f in "$TESTS_DIR"/*.test.sh; do [ -f "$f" ] && files+=("$f"); done
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "no test files matched" >&2
  exit 2
fi

if ! docker version >/dev/null 2>&1; then
  echo "${R}docker is unavailable.${N} 00-config-lint needs no docker; the rest do." >&2
  echo "On WSL: Docker Desktop → Settings → Resources → WSL Integration." >&2
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
