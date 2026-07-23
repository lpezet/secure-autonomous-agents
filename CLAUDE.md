# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker setup to run autonomous agents/harness (e.g. Claude Code) without exposing long-lived credentials to the agent's process. The agent's outbound HTTPS traffic is intercepted by mitmproxy, which injects credentials fetched from a broker the agent cannot reach directly.

## Architecture

```
[dev container]  ──HTTPS──►  [proxy: mitmproxy]  ──injects creds──►  external APIs
     │                              │
     │ git creds only               │ fetches creds from broker
     ▼                              ▼
[cred-gateway: nginx]  ──────►  [broker: Node.js]  ──reads──►  ~/.config/agent-creds/
```

**Two Docker networks enforce the security boundary:**

- `secure`: broker + proxy + cred-gateway. Dev container is **not** on this network.
- `dev`: dev + proxy + cred-gateway.

The broker is on `secure` only. Docker DNS will not resolve `broker` from within the dev container, and there is no route even if it did. The only broker-adjacent surface reachable from dev is the two nginx-whitelisted paths on cred-gateway.

**One directory per service, named after the service — in both `stack/` and `examples/`.**

```
                      stack/ (builds the image)      examples/ (supplies content)
broker         →      broker/providers/*.js          broker/*.js
proxy          →      proxy/addons/*.py              proxy/*.py
cred-gateway   →      cred-gateway/gateway.d/*.conf  cred-gateway/*.conf
dev            →      dev/Dockerfile                 dev/Dockerfile
```

`stack/` needs the extra `providers/` / `addons/` / `gateway.d/` level because those directories sit alongside the image's own files — `stack/broker/` also holds `Dockerfile`, `server.js`, `package.json`. An example's service directory holds nothing but the mounted content, so the level would be pure ceremony; the mount says where it lands:

```yaml
- ./broker:/app/providers:ro
- ./proxy:/addons:ro
- ./cred-gateway:/etc/nginx/gateway.d:ro
```

Which service owns a file is answered by the directory name, rather than by knowing that addons are a mitmproxy concept and providers a broker one. Keep new content under the service that consumes it.

### broker (`stack/broker/`)

Node.js HTTP server on `:8080`. Reads credentials from `/secrets` (bind-mounted from `~/.config/agent-creds/` on the host, read-only).

Route handlers live in `stack/broker/providers/` — one file per credential provider, bind-mounted into the container at `/app/providers/`. `server.js` loads all `*.js` files from that directory at startup and dispatches requests by pathname. Adding a new provider means dropping a file in `providers/` and restarting the broker. Exposed routes:

| Path | Who calls it | Notes |
|---|---|---|
| `/github/token` | proxy `010_github.py` | Installation token, cached with 5-min safety window |
| `/github/credential` | cred-gateway → dev git helper | Same token in `git credential` format |
| `/github/identity` | cred-gateway → setup-start.sh | App name+email for `git config`, lifetime-cached |
| `/anthropic/key` | proxy `020_anthropic.py` | Reads key file on each uncached call |
| `/cloudflare/token?profile=` | proxy `030_cloudflare.py` | Mints scoped token via Cloudflare API, cached per profile |
| `/healthz` | Docker healthcheck | |

The broker makes direct outbound HTTPS calls to `api.github.com` and `api.cloudflare.com` — it does **not** go through the proxy. Routing through the proxy would be circular (proxy fetches creds from broker to authenticate outbound calls).

### proxy (`stack/proxy/`)

mitmproxy with addons in `stack/proxy/addons/`, bind-mounted into the container at `/addons/`. `entrypoint.sh` globs `*.py` files from that directory at startup and passes them to `mitmdump` in alphabetical order — dropping a new addon file and restarting the container is sufficient to load it. Numeric prefixes control load order. Current addons:

- **`000_policy.py`** — blocks any request destined for `broker` or `cred-gateway` hostnames (defense-in-depth; Docker network isolation is the primary control). Must load first.
- **`010_github.py`** — matches `api.github.com` and `uploads.github.com` only. Fetches token from broker, injects as `Authorization: token ...`. Strips whatever the client sent. **Does not match `github.com`** — git push/pull goes through the credential helper path, not here.
- **`020_anthropic.py`** — matches `api.anthropic.com`. Injects the API key. Blocks `/v1/organizations/*` (Admin API). Uses `responseheaders` hook + `flow.response.stream = True` for SSE to avoid buffering streamed responses.
- **`030_cloudflare.py`** — matches `api.cloudflare.com`. Injects a scoped token. Caller can hint a profile via `X-Cf-Profile` header (stripped before forwarding); defaults to `workers-deploy`.

All addons cache credentials with a 5-minute TTL (`cachetools.TTLCache`). A 401 from GitHub clears the cache immediately.

### cred-gateway (`stack/cred-gateway/`)

nginx image built from `stack/cred-gateway/Dockerfile` — the `nginx.conf` is baked into the image at build time (not bind-mounted). This prevents runtime config substitution.

The base image ships **no** provider endpoints: `/healthz`, then `include /etc/nginx/gateway.d/*.conf`, then `location / { return 403; }`. Whitelisted endpoints come from a bind-mounted directory of snippets, mirroring how the broker gets `/app/providers` and the proxy gets `/addons` — base image is mechanism, the deployment supplies content. `stack/cred-gateway/gateway.d/` is empty (like `stack/broker/providers/`) and holds the authoring rules in its README.

Both examples vendor `cred-gateway/github.conf`, the counterpart to their `proxy/010_github.py` and `broker/github.js`:
- `GET /github/credential` — proxies to `broker:8080/github/credential`
- `GET /github/identity` — proxies to `broker:8080/github/identity`

Snippets must use exact-match locations (`location = /path`); a prefix match like `location /github/` would expose `/github/token`. The mount source must sit outside whatever is mounted at `/workspace`, or the dev container could widen its own whitelist — `examples/dev-container` mounts `../:/workspace` so it shadows `.devcontainer` with a nested read-only bind to close that.

Everything else returns 403. `/anthropic/key`, `/github/token`, and `/cloudflare/token` are intentionally not exposed — exposing them would allow the dev container to exfiltrate raw credentials.

### dev container (`stack/dev/`, `examples/*/dev/`)

`stack/dev/` is the minimal base image (Node 22 + curl + jq + ca-certificates). Individual examples extend it with their own `dev/Dockerfile` adding tools specific to that use case (e.g., `gh` CLI and `wrangler` in the dev-container example).

`setup.sh` (postCreateCommand, idempotent):
1. Installs the mitmproxy CA cert into the system trust store
2. Wires `git credential.helper` to `curl $GIT_CREDENTIAL_URL`
3. Forces `gh` to use HTTPS (not SSH) to prevent bypassing the proxy
4. Verifies broker is unreachable — exits non-zero if it is (security boundary broken)
5. Calls `setup-start.sh`

`setup-start.sh` (postStartCommand, runs on every restart):
1. Fetches GitHub App identity from cred-gateway and writes `git config user.name/email`
2. Smoke-checks that `gh api /rate_limit` works through the proxy

## Non-obvious invariants

**Never use `flow.request.pretty_host` for a security decision in an addon.** It prefers the client-supplied `Host` header, which the dev container fully controls, while mitmproxy connects to `flow.request.host` (absolute-form URI, CONNECT authority, or TLS SNI). Every addon originally matched `pretty_host`, which meant `curl --proxy http://proxy:8080 -H 'Host: api.anthropic.com' http://my-server/` made the proxy inject the real Anthropic key into a request delivered to `my-server`, and `-H 'Host: anything'` walked `000_policy.py` straight through to `broker:8080/github/token`. Always match on `flow.request.host`. `tests/integration/20`, `25` and `30` cover each addon.

**`GH_TOKEN=proxy-injected` and `CLOUDFLARE_API_TOKEN=proxy-injected` are dummy values.** They exist to satisfy client-side "am I authenticated?" checks in `gh` and `wrangler`. The proxy strips them at the wire level and injects real tokens. Do not replace them with real values — the whole point is that dev never holds real credentials.

**`010_github.py` must not match `github.com`.** Git push/pull to `github.com` goes through the HTTPS credential helper (via cred-gateway), not through token injection. Adding `github.com` to the addon would conflict with git's HTTP Basic auth handshake inside the MITMed tunnel.

**`020_anthropic.py` uses `responseheaders`, not `response`.** Accessing `flow.response.content` for a streamed response would buffer the entire body. The addon sets `flow.response.stream = True` in `responseheaders` so SSE chunks pass through immediately.

**The broker's `identityCache` is lifetime-cached.** If the GitHub App is renamed, restart the broker to refresh it. All other caches are TTL-based (5 minutes).

**CA cert persistence.** The mitmproxy CA cert lives in the `proxy-certs` named Docker volume, shared between the `proxy` container (where it's generated) and the `dev` container (read-only). The proxy's healthcheck gates on the cert file existing, so `postCreateCommand` cannot race cert generation. Removing the volume forces cert regeneration and requires a container rebuild.

**`credential.useHttpPath false` in git config** means one installation token is used for all repos regardless of path. This is intentional — the GitHub App's installation already scopes which repos it can access.

**Do not add `USER mitmproxy` to `proxy/Dockerfile`.** The base image (`mitmproxy/mitmproxy`) ships with a `docker-entrypoint.sh` that runs `usermod` (requires root) to align the `mitmproxy` user's UID with the mounted volume owner, then drops privileges via `gosu mitmproxy`. Adding `USER mitmproxy` makes the entrypoint run as non-root, causing `usermod` to fail with "operation not permitted". The `USER root` + `RUN pip install` block is correct; the entrypoint handles the privilege drop. Proxy stdout is also block-buffered when not attached to a tty — add `-e PYTHONUNBUFFERED=1` or `-it` when testing standalone to see logs in real time.

## Tests

Two tiers behind one facade. `tests/run.sh` dispatches to `tests/<tier>/run.sh` and passes the remaining arguments through.

- `tests/integration/` — the security boundaries, against stubs and fixtures. No credentials, free, ~60s. `00-config-lint.test.sh` needs no docker.
- `tests/e2e/` — the paths a stub cannot reach (HTTPS/CONNECT, CA cert lifecycle, `git push` through the credential helper), against a **dedicated** GitHub App and `~/.config/agent-creds-e2e`. Spends real API quota.

A bare `tests/run.sh` runs integration only — e2e must be asked for by name (`tests/run.sh e2e`, or `all` for both, fail-fast). `lib.sh` and `fixtures/` are shared. See `tests/README.md`.

## Adding a new credential provider

1. Add a credential file path env var under `broker` in the relevant `compose.yaml`
2. Add a provider file in `stack/broker/providers/` (follow existing pattern; expose via cred-gateway only if dev tools need raw access — almost never). Restart the broker to pick it up.
3. Add a numbered addon in `stack/proxy/addons/` following the `020_anthropic.py` or `030_cloudflare.py` pattern
4. Restart the proxy — `entrypoint.sh` auto-discovers `*.py` files in `/addons/` at startup, no Dockerfile change needed
5. Add a smoke-test section verifying injection works AND the broker endpoint is unreachable from dev
6. Add coverage in `tests/` — at minimum a spoofed-`Host` case proving the new addon does not inject for any host but the genuine one
