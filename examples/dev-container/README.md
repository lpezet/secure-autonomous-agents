# Dev Container Example

Runs your development environment inside a VS Code dev container with no credentials in the
container. Claude Code, `gh`, `wrangler`, and `git` all work through the proxy — their outbound
API calls are intercepted and real credentials are injected by the broker.

## Prerequisites

### Credential files

```bash
mkdir -p ~/.config/agent-creds && chmod 700 ~/.config/agent-creds

cp /path/to/your-app.private-key.pem ~/.config/agent-creds/github-app.pem
printf 'sk-ant-...' > ~/.config/agent-creds/anthropic.key
printf '<cloudflare-minter-token>' > ~/.config/agent-creds/cloudflare-minter.token
chmod 600 ~/.config/agent-creds/*
```

### `.env`

```bash
cd examples/dev-container/.devcontainer
cp .env.example .env
# fill in GITHUB_APP_ID and GITHUB_APP_INSTALLATION_ID
```

## Quick start

Open this directory in VS Code → **Dev Containers: Reopen in Container**.

VSCode runs `setup.sh` (on create) and `setup-start.sh` (on each start), which install the
mitmproxy CA cert, wire git credentials, verify the security boundary, and set git identity
from the GitHub App.

## Commands

All commands run from `examples/dev-container/`.

**Bring up the stack without VS Code (useful for CI or testing):**
```bash
docker compose -f .devcontainer/compose.yaml up --build -d
```

**Logs:**
```bash
docker compose -f .devcontainer/compose.yaml logs -f broker proxy cred-gateway
```

**Teardown** (removes volumes including the mitmproxy CA cert):
```bash
docker compose -f .devcontainer/compose.yaml down -v
```

**Restart after rotating a credential:**
```bash
docker compose -f .devcontainer/compose.yaml restart broker            # GitHub key, Cloudflare token
docker compose -f .devcontainer/compose.yaml restart broker proxy      # Anthropic key (proxy caches it)
```

**Force-regenerate the mitmproxy CA cert:**
```bash
docker compose -f .devcontainer/compose.yaml down
docker volume rm dev-container-agent_proxy-certs
docker compose -f .devcontainer/compose.yaml up -d
# Then: Dev Containers: Rebuild Container in VS Code
```

**Recovery if setup failed mid-run** (idempotent, run inside the dev container):
```bash
/workspace/.devcontainer/dev/setup.sh
```

## Testing the security boundary

Run these from inside the dev container (`docker compose -f .devcontainer/compose.yaml exec dev bash`):

```bash
# 1. Broker must be unreachable directly from dev
curl -s --max-time 2 http://broker:8080/healthz
# → curl: (6) Could not resolve host  OR  (28) Connection timed out

# 2. Proxy must block tunnelled requests to broker (000_policy.py)
curl -s -o /dev/null -w "%{http_code}" --proxy http://proxy:8080 http://broker:8080/healthz
# → 403

# 3. cred-gateway must deny endpoints that would expose raw credentials
curl -s -o /dev/null -w "%{http_code}" http://cred-gateway/anthropic/key
# → 403
curl -s -o /dev/null -w "%{http_code}" http://cred-gateway/github/token
# → 403

# 4. cred-gateway allows whitelisted endpoints
curl -sf http://cred-gateway/healthz
# → ok
curl -sf http://cred-gateway/github/credential | head -1
# → username=x-access-token

# 5. Anthropic API works through proxy (no ANTHROPIC_API_KEY in env)
curl -sf https://api.anthropic.com/v1/messages \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5","max_tokens":16,"messages":[{"role":"user","content":"Say PONG"}]}' \
  | jq -r '.content[0].text'
# → PONG

# 6. Anthropic Admin API is blocked by proxy
curl -s -o /dev/null -w "%{http_code}" https://api.anthropic.com/v1/organizations/api_keys
# → 403

# 7. GitHub API works through proxy (dummy GH_TOKEN, real token injected)
gh api /rate_limit | jq '.rate'
```

## Debug the proxy

Swap `mitmdump` for `mitmweb` in the proxy image CMD and publish port 8081 to get a browser UI
showing all intercepted requests. See the comment in `stack/proxy/Dockerfile`.
