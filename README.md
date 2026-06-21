# Secure Autonomous Agents

Docker infrastructure for running autonomous agents (e.g. Claude Code) without exposing
long-lived credentials to the agent's process. Outbound HTTPS is intercepted by mitmproxy,
which injects credentials fetched from a broker the agent cannot reach directly.

## Repository structure

```
stack/          Core reusable infrastructure (broker, proxy, cred-gateway, base dev image)
examples/
  dev-container/   VS Code dev container — open any repo in a secured workspace
  claude-code/     Claude Code in a secured container — attach and use interactively
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

### Why cred-gateway exists

Git authenticates to `github.com` via HTTP Basic auth inside the HTTPS tunnel — a different
flow from API calls. The proxy addon (`010_github.py`) deliberately does **not** match
`github.com`: injecting a token there would conflict with git's Basic auth handshake inside
the MITMed connection. So git credentials cannot go through the proxy injection path.

Instead, git is configured with a credential helper: `curl http://cred-gateway/github/credential`.
This is a direct HTTP call from the dev container (not proxied) that returns the token in
git's `username=x-access-token\npassword=<token>` format.

cred-gateway (nginx) sits on both networks and acts as the narrow bridge: it exposes only
`/github/credential` and `/github/identity` to the dev container, proxying those through to
the broker on `secure`. Raw credential endpoints (`/anthropic/key`, `/github/token`) return
403 — exposing them would let the dev container exfiltrate real secrets directly.

In short: the **proxy** handles API traffic via token injection; **cred-gateway** handles git's
credential helper via a tightly scoped nginx whitelist.

## Quick start

Each example is self-contained. See its README for prerequisites, credential setup, and
security boundary tests.

### VS Code dev container

Opens your repo in a credential-free workspace. Claude Code, `gh`, `wrangler`, and `git` all
work transparently — real credentials are injected at the network level.

```bash
cd examples/dev-container/.devcontainer
cp .env.example .env   # fill in GITHUB_APP_ID and GITHUB_APP_INSTALLATION_ID
```

Open `examples/dev-container/` in VS Code → **Dev Containers: Reopen in Container**.

See [`examples/dev-container/README.md`](examples/dev-container/README.md) for full setup.

### Claude Code in a secured container

Runs Claude Code inside the secure proxy stack with no credentials in the container.

```bash
cd examples/claude-code
cp .env.example .env   # fill in GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, ANTHROPIC_API_KEY
docker compose up --build -d
docker compose logs -f dev   # watch setup complete
```

See [`examples/claude-code/README.md`](examples/claude-code/README.md) for full setup.

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

Each line has the form:

```
domain [METHODS]
```

`domain` is an exact hostname or a wildcard (`*.example.com` matches all subdomains).
`METHODS` is an optional comma-separated list of HTTP methods to permit for that domain.
Omitting `METHODS` defaults to `GET,HEAD,OPTIONS` (safe reads only).
Use `*` to explicitly allow all methods.

```
# Default: GET, HEAD, OPTIONS only
storage.googleapis.com

# Explicit method list
api.example.com           GET,POST

# Opt in to all methods
uploads.example.com       *

# Wildcard subdomain restricted to writes
*.internal.example.com    PUT,POST,PATCH,DELETE
```

`CONNECT` is always permitted for allowlisted domains — it is required to establish HTTPS
tunnels. The actual HTTP method is enforced on the inner request inside the tunnel.

After editing the allowlist file, restart the proxy to pick up changes:
```bash
docker compose up -d --force-recreate proxy
```

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
