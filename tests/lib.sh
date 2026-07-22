#!/usr/bin/env bash
# Shared helpers for the regression suite. Source this at the top of a *.test.sh.
#
# Deliberately dependency-free: bash + docker only, no test framework, no
# network access beyond pulling the handful of stock images listed in IMAGES.
#
# Every resource created here is named with a per-run suffix and removed by an
# EXIT trap, so a suite run never collides with (or cleans up) a real stack the
# user has running.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
FIXTURES="$TESTS_DIR/fixtures"

# Unique per process so parallel or interrupted runs never clash.
RUN_ID="sattest-$$"
NET="$RUN_ID-net"

_PASS=0
_FAIL=0
_SKIP=0
_FAILED_LABELS=()
_TRACKED_CONTAINERS=()
_TRACKED_NETWORKS=()
_TRACKED_IMAGES=()

if [ -t 1 ]; then
  _G=$'\033[32m'; _R=$'\033[31m'; _Y=$'\033[33m'; _B=$'\033[1m'; _N=$'\033[0m'
else
  _G=''; _R=''; _Y=''; _B=''; _N=''
fi

# ---------------------------------------------------------------- assertions

ok()   { _PASS=$((_PASS+1)); printf '  %sPASS%s %s\n' "$_G" "$_N" "$1"; }
ko()   {
  _FAIL=$((_FAIL+1)); _FAILED_LABELS+=("$1")
  printf '  %sFAIL%s %s\n' "$_R" "$_N" "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
  return 0
}
skip() { _SKIP=$((_SKIP+1)); printf '  %sSKIP%s %s%s\n' "$_Y" "$_N" "$1" "${2:+ — $2}"; }

# check <label> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "expected: $2 | actual: $3"; fi
}

# check_contains <label> <haystack> <needle>
check_contains() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      ko "$1" "expected to contain: $3 | actual: $2" ;;
  esac
}

# check_not_contains <label> <haystack> <needle>
check_not_contains() {
  case "$2" in
    *"$3"*) ko "$1" "expected NOT to contain: $3 | actual: $2" ;;
    *)      ok "$1" ;;
  esac
}

suite() { printf '\n%s=== %s ===%s\n' "$_B" "$1" "$_N"; }

# Print summary and exit non-zero if anything failed.
finish() {
  printf '\n  %d passed, %d failed, %d skipped\n' "$_PASS" "$_FAIL" "$_SKIP"
  if [ "$_FAIL" -gt 0 ]; then
    printf '  failing:\n'
    for l in "${_FAILED_LABELS[@]}"; do printf '    - %s\n' "$l"; done
    exit 1
  fi
  exit 0
}

# ------------------------------------------------------------ docker helpers

# Stock images the suite pulls. Kept small and boring on purpose.
IMAGES=(nginx:alpine curlimages/curl:latest alpine:latest)

require_docker() {
  if ! docker version >/dev/null 2>&1; then
    printf '%sdocker is not available — cannot run this suite%s\n' "$_R" "$_N" >&2
    printf 'On WSL, check Docker Desktop → Settings → Resources → WSL Integration.\n' >&2
    exit 2
  fi
  _credstore_workaround
}

# Docker Desktop on WSL writes `"credsStore": "desktop.exe"` into
# ~/.docker/config.json. `docker build` invokes that helper even for public
# images, and the .exe is often not executable from inside the distro:
#   error getting credentials — fork/exec .../docker-credential-desktop.exe:
#   exec format error
# `docker run`/`pull` are unaffected, which makes it look intermittent.
# Point DOCKER_CONFIG at a scratch config when the helper cannot run. No-op
# when the configured store works, so authenticated pulls keep functioning.
_credstore_workaround() {
  local cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json" store
  [ -f "$cfg" ] || return 0
  store=$(sed -n 's/.*"credsStore"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null)
  [ -z "$store" ] && return 0
  if command -v "docker-credential-$store" >/dev/null 2>&1 &&
     "docker-credential-$store" list >/dev/null 2>&1; then
    return 0
  fi
  _SCRATCH_DOCKER_CONFIG=$(mktemp -d)
  printf '{}' > "$_SCRATCH_DOCKER_CONFIG/config.json"
  export DOCKER_CONFIG="$_SCRATCH_DOCKER_CONFIG"
  printf '  %snote:%s credsStore "%s" is not usable here — using a scratch docker config\n' \
    "$_Y" "$_N" "$store"
}

track_container() { _TRACKED_CONTAINERS+=("$1"); }
track_network()   { _TRACKED_NETWORKS+=("$1"); }
track_image()     { _TRACKED_IMAGES+=("$1"); }

cleanup() {
  local rc=$?
  [ "${#_TRACKED_CONTAINERS[@]}" -gt 0 ] && docker rm -f "${_TRACKED_CONTAINERS[@]}" >/dev/null 2>&1
  [ "${#_TRACKED_NETWORKS[@]}"   -gt 0 ] && docker network rm "${_TRACKED_NETWORKS[@]}" >/dev/null 2>&1
  # Images are kept by default: rebuilding them on every run is slow and they
  # are named with the run id only when explicitly tracked.
  [ "${KEEP_IMAGES:-0}" != "1" ] && [ "${#_TRACKED_IMAGES[@]}" -gt 0 ] && \
    docker rmi -f "${_TRACKED_IMAGES[@]}" >/dev/null 2>&1
  [ -n "${_SCRATCH_DOCKER_CONFIG:-}" ] && rm -rf "$_SCRATCH_DOCKER_CONFIG"
  return $rc
}
trap cleanup EXIT

net_up() {
  docker network create "$NET" >/dev/null
  track_network "$NET"
}

# Start the stub broker. Answers every path with "BROKER-HIT <uri>" so a test
# can tell "reached the broker" from "denied by the gateway" without needing
# real credentials.
#
# Extra network aliases can be passed as arguments (used by the allowlist tests).
stub_broker_up() {
  local name="$RUN_ID-broker" args=()
  local a; for a in "$@"; do args+=(--network-alias "$a"); done
  docker run -d --name "$name" --network "$NET" --network-alias broker "${args[@]}" \
    -v "$FIXTURES/stub-broker.conf:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine >/dev/null
  track_container "$name"
  wait_http "$name:8080/anything" 200 "stub broker"
}

# A long-lived curl container. One `docker run` per assertion is ~1s of
# overhead; `docker exec` into a warm container is ~50ms.
curl_up() {
  local name="$RUN_ID-curl"
  docker run -d --name "$name" --network "$NET" --entrypoint sleep \
    curlimages/curl:latest infinity >/dev/null
  track_container "$name"
  CURL_C="$name"
}

# http_code <url> [curl args...] → prints the status code
http_code() {
  local url="$1"; shift
  docker exec "$CURL_C" curl -s -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null
}

# http_body <url> [curl args...] → prints the response body
http_body() {
  local url="$1"; shift
  docker exec "$CURL_C" curl -s "$@" "$url" 2>/dev/null
}

# wait_http <host:port/path> <expected-code> <label> — poll until ready.
# Containers are not serving the instant `docker run` returns.
wait_http() {
  local target="$1" want="$2" label="$3" i
  for i in $(seq 1 40); do
    if [ -n "${CURL_C:-}" ]; then
      [ "$(http_code "http://$target")" = "$want" ] && return 0
    else
      # Before curl_up: use a throwaway container.
      [ "$(docker run --rm --network "$NET" curlimages/curl:latest \
            -s -o /dev/null -w '%{http_code}' "http://$target" 2>/dev/null)" = "$want" ] && return 0
    fi
    sleep 0.25
  done
  printf '%swarning:%s %s did not become ready (wanted %s from %s)\n' \
    "$_Y" "$_N" "$label" "$want" "$target" >&2
  return 1
}

# Build an image only if it is missing, unless FORCE_BUILD=1.
build_image() {
  local tag="$1" context="$2"
  if [ "${FORCE_BUILD:-0}" != "1" ] && docker image inspect "$tag" >/dev/null 2>&1; then
    return 0
  fi
  printf '  building %s from %s...\n' "$tag" "$context"
  if ! docker build -q -t "$tag" "$context" >/dev/null; then
    printf '%sbuild failed for %s%s\n' "$_R" "$tag" "$_N" >&2
    return 1
  fi
}
