#!/bin/bash
set -euo pipefail

/setup.sh

# Fix ownership of bind-mounted workspace dirs so agent user can write to them.
chown -R agent:agent /home/agent/.claude /home/agent/.config 2>/dev/null || true
[ -f /home/agent/.claude.json ] && chown agent:agent /home/agent/.claude.json || true

# claude misbehaves when started as a detached Docker entrypoint (TTY/signal environment
# differs from an interactive exec session). We keep the container alive with sleep infinity
# and run claude via `docker compose exec` through `run.sh <agent> attach` instead.
exec sleep infinity