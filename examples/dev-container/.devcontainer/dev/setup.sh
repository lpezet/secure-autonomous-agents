#!/bin/bash
# postCreateCommand — runs once when the container is first created.
# Re-runnable (all steps are idempotent). If this fails mid-run,
# fix the issue and re-run: /workspace/.devcontainer/dev/setup.sh
set -euo pipefail

echo "[setup] trusting mitmproxy CA cert..."
sudo cp /proxy-certs/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
sudo update-ca-certificates

echo "[setup] configuring git credential helper..."
git config --global credential.helper "!f() { curl -s \"\$GIT_CREDENTIAL_URL\"; }; f"
git config --global credential.useHttpPath false

# Prevent gh from attempting SSH, which bypasses the HTTPS proxy/credential path.
# gh with GH_TOKEN env var does not write to ~/.config/gh/hosts.yml.
gh config set --host github.com git_protocol https

echo "[setup] verifying network isolation (broker must be unreachable)..."
if curl -s --max-time 2 http://broker:8080/healthz > /dev/null 2>&1; then
  echo "[setup] FAIL: broker is reachable from dev container — security boundary broken!"
  exit 1
else
  echo "[setup] OK: broker is not reachable from dev (expected)"
fi

# Run the per-start tasks (identity fetch, connectivity check) on first create too.
/workspace/.devcontainer/dev/setup-start.sh
