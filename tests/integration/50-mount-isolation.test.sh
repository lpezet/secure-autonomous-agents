#!/usr/bin/env bash
# Mount isolation for examples/dev-container.
#
# That example mounts ../ — the parent of .devcontainer — read-write at
# /workspace so the agent can work on the project. Without a nested read-only
# bind, the agent can rewrite the stack's own config: neuter 000_policy.py,
# add a prefix-match location exposing /github/token, or point a provider at
# an attacker-controlled host. It cannot restart the containers itself, but the
# edit persists and takes effect the next time a human does.
#
# Replays the mount arguments exactly as declared in that example's compose.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker

EX="$REPO_ROOT/examples/dev-container"
COMPOSE="$EX/.devcontainer/compose.yaml"

suite "compose declares both mounts"
check_contains "workspace bind present" "$(cat "$COMPOSE")" '../:/workspace'
check_contains "nested read-only shadow present" "$(cat "$COMPOSE")" '../.devcontainer:/workspace/.devcontainer:ro'

suite "runtime behaviour of the mount pair"
probe() { # probe <path> → WRITABLE | read-only
  docker run --rm \
    -v "$EX:/workspace" \
    -v "$EX/.devcontainer:/workspace/.devcontainer:ro" \
    alpine sh -c "touch '$1' 2>/dev/null && { rm -f '$1'; echo WRITABLE; } || echo read-only"
}

check "project files stay writable" "WRITABLE" "$(probe /workspace/probe)"
check "proxy/ is read-only"        "read-only" "$(probe /workspace/.devcontainer/proxy/probe)"
check "broker/ is read-only"       "read-only" "$(probe /workspace/.devcontainer/broker/probe)"
check "cred-gateway/ is read-only" "read-only" "$(probe /workspace/.devcontainer/cred-gateway/probe)"
check "compose.yaml is read-only"  "read-only" "$(probe /workspace/.devcontainer/compose.yaml)"

suite "existing stack config cannot be modified"
# The failure message comes from the shell, not from echo, so the redirect has
# to be on `docker run` itself.
modify() {
  docker run --rm \
    -v "$EX:/workspace" \
    -v "$EX/.devcontainer:/workspace/.devcontainer:ro" \
    alpine sh -c "echo x >> '$1'" 2>&1 || true
}
check_contains "cannot append to 000_policy.py" \
  "$(modify /workspace/.devcontainer/proxy/000_policy.py)" "Read-only file system"
check_contains "cannot append to gateway.d/github.conf" \
  "$(modify /workspace/.devcontainer/cred-gateway/github.conf)" "Read-only file system"
check_contains "cannot append to compose.yaml" \
  "$(modify /workspace/.devcontainer/compose.yaml)" "Read-only file system"

suite "no fixture residue"
# Scoped to probe artefacts: a plain `git status` here would also flag whatever
# legitimate edits are in flight, which is not what this is checking.
check "no probe files left in the example" "" "$(find "$EX" -name 'probe' -print 2>/dev/null)"
check "read-only targets were not appended to" "" \
  "$(git diff --stat -- examples/dev-container/.devcontainer/compose.yaml \
       examples/dev-container/.devcontainer/cred-gateway/ | grep -E '^\s*x$' || true)"

finish
