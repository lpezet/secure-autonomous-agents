#!/bin/bash
# postStartCommand — runs each time the container starts (including after restart).
# Refreshes git identity from the broker in case the GitHub App was reconfigured.
set -euo pipefail

echo "[setup-start] waiting for identity endpoint (cred-gateway → broker → GitHub)..."
READY=false
for i in 1 2 3 4 5; do
  if curl -sf "$GITHUB_IDENTITY_URL" >/dev/null 2>&1; then
    READY=true
    break
  fi
  echo "[setup-start] not ready (attempt $i/5)..."
  sleep 2
done

if [ "$READY" = true ] && IDENTITY_JSON=$(curl -sf "$GITHUB_IDENTITY_URL" 2>/dev/null); then
  GIT_NAME=$(echo "$IDENTITY_JSON" | jq -r .name)
  GIT_EMAIL=$(echo "$IDENTITY_JSON" | jq -r .email)
  git config --global user.name "$GIT_NAME"
  git config --global user.email "$GIT_EMAIL"
  echo "[setup-start] git identity set: $GIT_NAME <$GIT_EMAIL>"
else
  echo "[setup-start] WARNING: identity fetch failed — skipping git identity (commits will use default git config)"
  echo "[setup-start]          diagnose: docker compose -f .devcontainer/compose.yaml logs broker"
  echo "[setup-start]          rerun when fixed: /workspace/.devcontainer/dev/setup-start.sh"
fi

echo "[setup-start] verifying proxy interception (gh through proxy with dummy GH_TOKEN)..."
if gh api /rate_limit > /dev/null 2>&1; then
  echo "[setup-start] proxy OK"
else
  echo "[setup-start] WARNING: gh api call failed; check proxy logs"
fi

echo "[setup-start] done."
