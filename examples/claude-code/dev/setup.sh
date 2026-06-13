#!/bin/bash
# One-time setup: trust the mitmproxy CA cert, wire git credentials, verify
# the security boundary, and fetch GitHub identity for git config.
# Idempotent — safe to re-run if something failed mid-way.
set -euo pipefail

echo "[setup] trusting mitmproxy CA cert..."
sudo cp /proxy-certs/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
sudo update-ca-certificates

echo "[setup] configuring git credential helper..."
git config --global credential.helper "!f() { curl -s \"\$GIT_CREDENTIAL_URL\"; }; f"
git config --global credential.useHttpPath false

# Prevent gh from attempting SSH, which would bypass the HTTPS proxy/credential path.
gh config set --host github.com git_protocol https

echo "[setup] verifying network isolation (broker must be unreachable from this container)..."
if curl -s --max-time 2 http://broker:8080/healthz > /dev/null 2>&1; then
  echo "[setup] FAIL: broker is reachable — security boundary broken!"
  exit 1
fi
echo "[setup] OK: broker unreachable (expected)"

echo "[setup] fetching GitHub identity for git config..."
for i in 1 2 3 4 5; do
  if IDENTITY_JSON=$(curl -sf "$GITHUB_IDENTITY_URL" 2>/dev/null); then
    git config --global user.name "$(echo "$IDENTITY_JSON" | jq -r .name)"
    git config --global user.email "$(echo "$IDENTITY_JSON" | jq -r .email)"
    echo "[setup] git identity: $(git config --global user.name) <$(git config --global user.email)>"
    break
  fi
  echo "[setup] identity not ready (attempt $i/5), retrying..."
  sleep 2
done

echo "[setup] done."
