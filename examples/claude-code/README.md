# Claude Code in a Secured Container

Runs Claude Code inside the secure proxy stack. No credentials are present in the container —
the Anthropic API key and GitHub tokens are injected at the network level by mitmproxy. Claude
Code cannot exfiltrate credentials even if it tries.

## Prerequisites

### Credentials

The GitHub App private key must be a file (it's a PEM cert):

```bash
mkdir -p ~/.config/agent-creds && chmod 700 ~/.config/agent-creds
cp /path/to/your-app.private-key.pem ~/.config/agent-creds/github-app.pem
chmod 600 ~/.config/agent-creds/*
```

The Anthropic API key goes in `.env` and is read directly by the broker — it never reaches
the agent container:

```bash
cd examples/claude-code
cp .env.example .env
# fill in GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, and ANTHROPIC_API_KEY
```

## Quick start

Create the workspace directory and seed the files that will be bind-mounted into the
container (Docker requires these to exist before `up` or it creates directories instead
of files where files are expected):

```bash
cd examples/claude-code
mkdir -p workspace/.claude workspace/.config
echo '{}' > workspace/.claude.json
touch workspace/CLAUDE.md
```

`workspace/CLAUDE.md` is mounted read-only as the agent's global instructions file.
Edit it to give Claude Code standing instructions before starting. `workspace/.claude/`
persists Claude Code's state (projects, memory, hooks) across container restarts.

```bash
docker compose up --build -d
docker compose logs -f dev   # watch setup complete
```

On startup `dev/entrypoint.sh` calls `setup.sh`, which:
1. Trusts the mitmproxy CA cert (so Claude Code's HTTPS calls go through the proxy)
2. Wires the git credential helper to cred-gateway
3. Verifies the broker is unreachable (security boundary check)
4. Fetches the GitHub App identity and writes `git config user.name/email`

## Attach

Once setup completes, attach an interactive Claude Code session:

```bash
docker compose exec -it dev claude
```

Point it at a workspace repo:

```bash
docker compose exec -it dev claude /workspace
```

## Commands

All commands run from `examples/claude-code/`.

**Logs:**
```bash
docker compose logs -f broker proxy cred-gateway dev
```

**Teardown** (removes volumes including the mitmproxy CA cert):
```bash
docker compose down -v
```

**Open a shell in the container** (for debugging):
```bash
docker compose exec dev bash
```

**Re-run setup if it failed mid-way** (idempotent):
```bash
docker compose exec dev /setup.sh
```

**Restart after rotating a credential:**
```bash
docker compose up -d --force-recreate broker          # GitHub App private key (replace file, then restart)
# Anthropic key: edit ANTHROPIC_API_KEY in .env, then:
docker compose up -d --force-recreate broker proxy    # proxy restart needed — it caches the key for 5 min
```

**Force-regenerate the mitmproxy CA cert:**
```bash
docker compose down
docker volume rm claude-code-agent_proxy-certs
docker compose up -d
```

## Testing the security boundary

Run these from inside the container (`docker compose exec dev bash`):

```bash
# 1. Broker must be unreachable directly from the container
curl -s --max-time 2 http://broker:8080/healthz
# → curl: (6) Could not resolve host  OR  (28) Connection timed out

# 2. Proxy must block tunnelled requests to broker (000_policy.py)
curl -s -o /dev/null -w "%{http_code}" --proxy http://proxy:8080 http://broker:8080/healthz
# → 403

# 3. cred-gateway must deny raw credential endpoints
curl -s -o /dev/null -w "%{http_code}" http://cred-gateway/anthropic/key
# → 403
curl -s -o /dev/null -w "%{http_code}" http://cred-gateway/github/token
# → 403

# 4. Anthropic API works through proxy (ANTHROPIC_API_KEY=proxy-injected dummy is replaced)
curl -sf https://api.anthropic.com/v1/messages \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5","max_tokens":16,"messages":[{"role":"user","content":"Say PONG"}]}' \
  | jq -r '.content[0].text'
# → PONG

# 5. Anthropic Admin API is blocked by proxy (020_anthropic.py)
curl -s -o /dev/null -w "%{http_code}" https://api.anthropic.com/v1/organizations/api_keys
# → 403

# 6. GitHub API works through proxy (dummy GH_TOKEN replaced by proxy)
gh api /rate_limit | jq '.rate'

# 7. Claude Code can reach the Anthropic API
claude -p "Reply with one word: PONG"
```

## Workspace

Uncomment the workspace volume in `compose.yaml` and point it at the repo Claude Code should
work on:

```yaml
volumes:
  - /path/to/your/project:/workspace
```

## Extending

To drive Claude Code autonomously, replace `exec sleep infinity` in `dev/entrypoint.sh` with
a channel listener that invokes:

```bash
claude -p "$task" --allowedTools "Bash,Read,Write,Edit" /workspace
```
