#!/bin/bash
# One-time plugin setup for the claude-code agent workspace.
# Idempotent — safe to re-run.
set -euo pipefail

# Fix ownership of bind-mounted workspace dirs so agent user can write to them.
chown -R agent:agent /home/agent/.claude /home/agent/.config 2>/dev/null || true
[ -f /home/agent/.claude.json ] && chown agent:agent /home/agent/.claude.json || true

echo "[plugins] adding agentlink marketplace..."
gosu agent claude plugin marketplace add https://github.com/lpezet/agentlink-plugins.git

echo "[plugins] adding claude-plugins-official marketplace..."
gosu agent claude plugin marketplace add anthropics/claude-plugins-official

echo "[plugins] installing plugins..."
#gosu agent claude plugin install agentlink-botcha-ai@agentlink-plugins
#gosu agent claude plugin install agentlink-artist@agentlink-plugins
gosu agent claude plugin install telegram@claude-plugins-official

echo "[plugins] done."
