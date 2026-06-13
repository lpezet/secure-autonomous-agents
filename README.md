# Secure Autonomous Agents

Docker infrastructure for running autonomous agents (e.g. Claude Code) without exposing
long-lived credentials to the agent's process. Outbound HTTPS is intercepted by mitmproxy,
which injects credentials fetched from a broker the agent cannot reach directly.

## Repository structure

```
stack/          Core reusable infrastructure (broker, proxy, cred-gateway, base dev image)
examples/
  dev-container/   VS Code dev container — open any repo in a secured workspace
  claude-code/     Headless Claude Code agent — receives tasks, runs autonomously
```

Each example's `compose.yaml` builds `broker`, `proxy`, and `cred-gateway` directly from
this repo's GitHub URL, so you only need the example directory itself to get started.

## How it works

```
┌─────────────────────────────────────────┐
│  dev container (Claude Code, git, gh)   │
│  HTTPS_PROXY=http://proxy:8080          │  network: dev
│  GIT_CREDENTIAL_URL=http://cred-gateway │
│  No credentials, no .env, no API keys   │
└────┬─────────────────────────┬──────────┘
     │ HTTPS (intercepted)     │ git creds only
     ▼                         ▼
┌──────────────┐   ┌─────────────────────┐
│  proxy       │   │  cred-gateway       │
│  mitmproxy   │   │  nginx, whitelist:  │
│  + addons    │   │  /github/credential │
│              │   │  /github/identity   │
└──────┬───────┘   └──────────┬──────────┘
       │                      │
       │     network: secure  │
       │     (no dev access)  │
       ▼                      ▼
┌─────────────────────────────────────────┐
│  broker                                 │
│  - Reads .pem / api keys from /secrets  │
│  - Mints GitHub installation tokens     │
│  - Injects Anthropic API key            │
│  - Mints scoped Cloudflare tokens       │
└─────────────────────────────────────────┘
             │
             ▼
        ~/.config/agent-creds/   (read-only bind mount)
```

Two Docker networks enforce the boundary:

- `secure` — broker, proxy, cred-gateway. The dev container is **not** on this network.
- `dev` — dev, proxy, cred-gateway.

The broker is on `secure` only. Docker DNS will not resolve `broker` from the dev container,
and there is no route even if it did. The only broker-adjacent surface reachable from dev is
the two paths nginx explicitly whitelists in `cred-gateway`.

## Prerequisites

### GitHub App

Create a GitHub App with these **repository permissions** (minimum):

- Contents: Read & Write
- Metadata: Read (auto-included)
- Pull requests: Read & Write
- Issues: Read & Write (if the agent files issues)
- Workflows: Read & Write (only if the agent edits `.github/workflows/`)

No webhook required.

**Steps:**

1. GitHub → Settings → Developer settings → GitHub Apps → New GitHub App
2. Generate a private key and download the `.pem` file
3. Note the **App ID** from the App's settings page
4. Install the App on the org/account: "Install App" tab → choose target → choose repos
5. After install, note the **Installation ID** — it's the trailing number in the URL,
   e.g. `https://github.com/settings/installations/78901234` → ID is `78901234`
6. The App must be installed on every repo the agent will touch

### Credential files

```bash
mkdir -p ~/.config/agent-creds
chmod 700 ~/.config/agent-creds

# GitHub App private key (required by all examples)
cp /path/to/your-app.private-key.pem ~/.config/agent-creds/github-app.pem

# Anthropic API key — use printf to avoid a trailing newline
printf 'sk-ant-...' > ~/.config/agent-creds/anthropic.key

# Cloudflare minter token (only needed if using the Cloudflare provider)
# Requires "User API Tokens:Edit" permission
printf '<token>' > ~/.config/agent-creds/cloudflare-minter.token

chmod 600 ~/.config/agent-creds/*
```

> **Note:** The `claude-code` example reads `ANTHROPIC_API_KEY` from `.env` rather than from a
> file. See `examples/claude-code/.env.example` for details.

## Quick start

### VS Code dev container

Opens your repo in a credential-free workspace. Claude Code, `gh`, `wrangler`, and `git` all
work transparently — real credentials are injected at the network level.

```bash
cd examples/dev-container/.devcontainer
cp .env.example .env
# fill in GITHUB_APP_ID and GITHUB_APP_INSTALLATION_ID
```

Open `examples/dev-container/` in VS Code → **Dev Containers: Reopen in Container**.

See [`examples/dev-container/README.md`](examples/dev-container/README.md) for operations,
credential rotation, and security boundary tests.

### Headless Claude Code agent

Runs Claude Code as a background agent with no credentials in the container.

```bash
cd examples/claude-code
cp .env.example .env
# fill in GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, and ANTHROPIC_API_KEY

# Create workspace files Docker needs before first up
mkdir -p workspace/.claude workspace/.config
echo '{}' > workspace/.claude.json
touch workspace/CLAUDE.md

docker compose up --build -d
docker compose logs -f dev   # watch setup complete
```

See [`examples/claude-code/README.md`](examples/claude-code/README.md) for workspace setup,
channel integration, and security boundary tests.

## Extending the stack

### Adding a credential provider

1. Drop a provider file in the example's `providers/` directory following the existing pattern.
   Restart the broker to pick it up — no image rebuild needed.
2. Add a numbered addon in the example's `addons/` directory following `020_anthropic.py` or
   `030_cloudflare.py`. Restart the proxy — `entrypoint.sh` auto-discovers `*.py` files at
   startup.
3. Add a smoke-test assertion verifying injection works and the broker endpoint is unreachable
   from the dev container.

### Proxy allowlist

The proxy can restrict outbound destinations to an explicit allowlist. Uncomment the allowlist
volume in `compose.yaml` and copy `stack/proxy/allowlist.sample` to `proxy/allowlist/001_allowlist.py`
(or any numbered `.py` file in that directory). Edit the file to define allowed hostnames.

## Security notes

- `GH_TOKEN=proxy-injected` and `ANTHROPIC_API_KEY=proxy-injected` are deliberate dummy
  values. They satisfy client-side "am I authenticated?" checks without holding real secrets.
  The proxy strips them at the wire and injects the real credentials.
- `000_policy.py` blocks any proxied request targeting `broker` or `cred-gateway` hostnames
  as defense-in-depth on top of Docker network isolation.
- `020_anthropic.py` blocks `/v1/organizations/*` (Anthropic Admin API) — the agent can use
  the API but cannot enumerate or manage org resources.
- The broker never routes through the proxy. It makes direct HTTPS calls to `api.github.com`
  and `api.cloudflare.com`. Routing through the proxy would be circular.
