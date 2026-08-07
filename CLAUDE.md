# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker setup to run autonomous agents/harness (e.g. Claude Code) without exposing long-lived credentials to the agent's process. The agent's outbound HTTPS traffic is intercepted by mitmproxy, which injects credentials fetched from a broker the agent cannot reach directly.

## Architecture

```
[lab container]  ──HTTPS──►  [proxy: mitmproxy]  ──injects creds──►  external APIs
     │                              │
     │ git creds only               │ fetches creds from broker
     ▼                              ▼
[cred-gateway: nginx]  ──────►  [broker: Node.js]  ──reads──►  ~/.config/agent-creds/
     │                              │
     │                              │  JSONL, no secret values
     ▼                              ▼
              [audit-logs volume]
             │                    │
             ▼                    ▼
    [log-rotator: cron+logrotate] [observer: :9000, loopback-only]
```

broker, proxy, and cred-gateway each write a structured JSONL audit trail (what got injected/blocked/issued, never a credential value) to a shared `audit-logs` named volume. `observer` tails it and serves a live view; `log-rotator` keeps it bounded. Neither has a `networks:` entry — they reach the volume without joining `secure` or `lab`, so the audit trail cannot become a new channel between the two. See the `observer` and `log-rotator` sections below.

**Two Docker networks enforce the security boundary:**

- `secure`: broker + proxy + cred-gateway. Dev container is **not** on this network.
- `lab`: lab + proxy + cred-gateway. **`internal: ${LAB_INTERNAL:-true}`** — no
  default gateway, so the proxy is the only way out and the allowlist is
  enforcing rather than advisory. `secure` is *not* internal: the broker needs
  direct egress to provider APIs.

The broker is on `secure` only. Docker DNS will not resolve `broker` from within the lab container, and there is no route even if it did. The only broker-adjacent surface reachable from lab is the two nginx-whitelisted paths on cred-gateway.

**One directory per service, named after the service — in both `stack/` and `examples/`.**

```
                      stack/ (builds the image)      examples/ (supplies content)
broker         →      broker/providers/*.js          broker/*.js
proxy          →      proxy/addons/*.py              proxy/*.py
cred-gateway   →      cred-gateway/gateway.d/*.conf  cred-gateway/*.conf
lab            →      lab/Dockerfile                 lab/Dockerfile
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
| `/github/token` | proxy `010_github.py` | Installation token, cached with 5-min safety window. Audits the scope it carries (`permissions`, `repository_selection`) |
| `/github/credential` | cred-gateway → lab git helper | Same token in `git credential` format, same scope audited |
| `/github/identity` | cred-gateway → setup-start.sh | App name+email for `git config`, lifetime-cached |
| `/anthropic/cred` | proxy `020_anthropic.py` | Returns `{type, value}`; prefers `ANTHROPIC_AUTH_TOKEN_PATH` (OAuth) over `ANTHROPIC_API_KEY_PATH`, read fresh on each uncached call |
| `/cloudflare/token?profile=` | proxy `030_cloudflare.py` | Mints scoped token via Cloudflare API, cached per profile |
| `/healthz` | Docker healthcheck | |

The broker makes direct outbound HTTPS calls to `api.github.com` and `api.cloudflare.com` — it does **not** go through the proxy. Routing through the proxy would be circular (proxy fetches creds from broker to authenticate outbound calls).

`stack/broker/audit.js`, baked into the image alongside `server.js`, is a JSONL writer any provider can use: `require("../audit").logEvent("token_issued", { provider: "github" })`. It writes to `AUDIT_LOG` if set and is a silent no-op otherwise, so providers that call it keep working in deployments that have not wired up the `audit-logs` volume. Log the shape of what happened, never a credential value.

### proxy (`stack/proxy/`)

mitmproxy with addons in `stack/proxy/addons/`, bind-mounted into the container at `/addons/`. `entrypoint.sh` globs `*.py` files from that directory at startup and passes them to `mitmdump` in alphabetical order — dropping a new addon file and restarting the container is sufficient to load it. Numeric prefixes control load order. Current addons:

- **`000_policy.py`** — blocks any request destined for `broker` or `cred-gateway` hostnames (defense-in-depth; Docker network isolation is the primary control). Must load first.
- **`010_github.py`** — matches `api.github.com` and `uploads.github.com` only. Fetches token from broker, injects as `Authorization: token ...`. Strips whatever the client sent. **Does not match `github.com`** — git push/pull goes through the credential helper path, not here.
- **`020_anthropic.py`** — matches `api.anthropic.com`. Injects the API key. Blocks `/v1/organizations/*` (Admin API). Uses `responseheaders` hook + `flow.response.stream = True` for SSE to avoid buffering streamed responses.
- **`030_cloudflare.py`** — matches `api.cloudflare.com`. Injects a scoped token. Caller can hint a profile via `X-Cf-Profile` header (stripped before forwarding); defaults to `workers-deploy`.

All addons cache credentials with a 5-minute TTL (`cachetools.TTLCache`). A 401 from GitHub clears the cache immediately.

`stack/proxy/audit.py` is baked into the image at `/opt/agent-proxy` and put on `PYTHONPATH` (see Dockerfile) so any addon — including ones bind-mounted from an example — can `import audit` and call `audit.log_event("blocked", host=host)` regardless of load order. Same no-op-when-`AUDIT_LOG`-unset behavior as the broker's `audit.js`.

### cred-gateway (`stack/cred-gateway/`)

nginx image built from `stack/cred-gateway/Dockerfile` — the `nginx.conf` is baked into the image at build time (not bind-mounted). This prevents runtime config substitution.

The base image ships **no** provider endpoints: `/healthz`, then `include /etc/nginx/gateway.d/*.conf`, then `location / { return 403; }`. Whitelisted endpoints come from a bind-mounted directory of snippets, mirroring how the broker gets `/app/providers` and the proxy gets `/addons` — base image is mechanism, the deployment supplies content. `stack/cred-gateway/gateway.d/` is empty (like `stack/broker/providers/`) and holds the authoring rules in its README.

Both examples vendor `cred-gateway/github.conf`, the counterpart to their `proxy/010_github.py` and `broker/github.js`:
- `GET /github/credential` — proxies to `broker:8080/github/credential`
- `GET /github/identity` — proxies to `broker:8080/github/identity`

Snippets must use exact-match locations (`location = /path`); a prefix match like `location /github/` would expose `/github/token`. The mount source must sit outside whatever is mounted at `/workspace`, or the lab container could widen its own whitelist — `examples/dev-container` mounts `../:/workspace` so it shadows `.devcontainer` with a nested read-only bind to close that.

Everything else returns 403. `/anthropic/cred`, `/github/token`, and `/cloudflare/token` are intentionally not exposed — exposing them would allow the lab container to exfiltrate raw credentials.

cred-gateway also writes a JSON audit line per request (`log_format audit_json` in `nginx.conf`) to `/var/log/audit/cred-gateway.jsonl`, separate from the existing stdout access log. `/healthz` opts out via `access_log off;` in its location block so healthchecks do not spam the trail. Unlike the broker/proxy helpers this is not opt-in: nginx opens configured `access_log` targets at startup and fails hard if the directory is missing, so the Dockerfile bakes in an empty `/var/log/audit` (same "valid unmounted" treatment as `gateway.d`) — the runtime volume mount just shadows it.

### observer (`stack/observer/`)

Node HTTP server on `:9000`, dependency-free like the broker. Polls `/var/log/audit/*.jsonl` every 500ms, broadcasts new lines over SSE at `/events`, and serves a minimal live-stream dashboard at `/`. Keeps a 200-event in-memory backlog so a client that connects mid-run sees recent history immediately.

Read-only consumer: mounts the `audit-logs` volume `:ro` and holds no credentials — but note it is the one service whose safety the stack cannot supply. It publishes over HTTP whatever the trail contains, and the images write no events themselves: every line comes from a bind-mounted provider or addon file the deployment owns. `observer` is therefore only as leak-free as those files are, which is why `PLAYBOOK.md`'s "What is safe to log" is addressed to whoever writes them. Detects `log-rotator`'s `copytruncate` rotation (file size shrinking means "start over from offset 0") rather than needing a reopen signal. Not on `secure` or `lab` — see "Non-obvious invariants" below — and its published port is bound to `127.0.0.1` on the host, so it's viewable from outside the stack but not from inside it.

### log-rotator (`stack/log-rotator/`)

Alpine + `logrotate` + busybox `crond`, mounting `audit-logs` read-write. `entrypoint.sh` runs `mkdir -p /var/log/audit && chmod 1777 /var/log/audit` on every start — idempotent, self-healing — then `crond` runs `logrotate` hourly against `/etc/logrotate.d/audit-logs` (`daily` + `maxsize 50M`, `rotate 14`, `dateext`, `copytruncate`).

Runs as root, unlike every other service in this stack. That's deliberate here, not an oversight: broker (`node`) and proxy (`mitmproxy`) are different non-root uids writing into the same shared directory, and only a root process can reliably chmod it for both and copytruncate files regardless of which uid created them.

### lab container (`stack/lab/`, `examples/*/lab/`)

`stack/lab/` is the minimal base image (Node 22 + curl + jq + ca-certificates). Individual examples extend it with their own `lab/Dockerfile` adding tools specific to that use case (e.g., `gh` CLI and `wrangler` in the dev-container example).

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

**Never use `flow.request.pretty_host` for a security decision in an addon** — see `PLAYBOOK.md`'s generation constraints for the rule (match `flow.request.host` instead). Concretely, every addon originally matched `pretty_host`, which meant `curl --proxy http://proxy:8080 -H 'Host: api.anthropic.com' http://my-server/` made the proxy inject the real Anthropic key into a request delivered to `my-server`, and `-H 'Host: anything'` walked `000_policy.py` straight through to `broker:8080/github/token`. `tests/integration/20`, `25` and `30` cover each addon against regressing on this.

**`GH_TOKEN=proxy-injected` and `CLOUDFLARE_API_TOKEN=proxy-injected` are dummy values, never real ones** — see `PLAYBOOK.md`'s Known Providers / generation constraints for why.

**`010_github.py` must not match `github.com`** — see `PLAYBOOK.md`'s GitHub section for why (conflicts with git's own Basic-auth handshake inside the MITM'd tunnel for push/pull).

**`020_anthropic.py` uses `responseheaders`, not `response`** — see `PLAYBOOK.md`'s Anthropic section for why (avoids buffering streamed SSE responses).

**The broker's `identityCache` and `installationScopeCache` are lifetime-cached.** Both describe things only a human changes in GitHub's UI — the App's name, and whether the installation is granted `all` repositories or `selected` ones. Restart the broker to refresh either. All other caches are TTL-based (5 minutes).

**`repository_selection` needs its own API call; `permissions` does not.** `auth({ type: "installation" })` returns `permissions` on the authentication object, so `github.js` gets it free. It does *not* return `repository_selection`, and `repositoryIds`/`repositoryNames` appear only when passed *in* as narrowing options — which the broker does not do. So the installation's repository scope is unknowable from the token itself, and `getInstallationScope()` calls `GET /app/installations/{id}` with the App JWT to get it. Do not "simplify" that away by reading it off the auth object.

**CA cert persistence.** The mitmproxy CA cert lives in the `proxy-certs` named Docker volume, shared between the `proxy` container (where it's generated) and the `lab` container (read-only). The proxy's healthcheck gates on the cert file existing, so `postCreateCommand` cannot race cert generation. Removing the volume forces cert regeneration and requires a container rebuild.

**`credential.useHttpPath false` in git config** is intentional, not a bug — see `PLAYBOOK.md`'s GitHub section for why.

**Do not add `USER mitmproxy` to `proxy/Dockerfile`** — see `PLAYBOOK.md`'s generation constraints for the rule. Mechanism: the base image (`mitmproxy/mitmproxy`) ships a `docker-entrypoint.sh` that runs `usermod` (requires root) to align the `mitmproxy` user's UID with the mounted volume owner, then drops privileges via `gosu mitmproxy`. Adding `USER mitmproxy` makes the entrypoint run as non-root, causing `usermod` to fail with "operation not permitted". The `USER root` + `RUN pip install` block is correct; the entrypoint handles the privilege drop. Proxy stdout is also block-buffered when not attached to a tty — add `-e PYTHONUNBUFFERED=1` or `-it` when testing standalone to see logs in real time.

**`observer` and `log-rotator` deliberately have no `networks:` entry in `compose.yaml`** — see `PLAYBOOK.md`'s generation constraints for the mechanism and why not to "fix" it.

**Examples do not pick up `stack/` changes until they repin their build tag.** `stack/broker/audit.js` and `stack/proxy/audit.py` are baked into the image; example provider/addon files under `examples/*/broker/` and `examples/*/proxy/` are bind-mounted at runtime into whatever tag that example's `compose.yaml` builds from (`...git#vX.Y.Z:stack/broker`). Adding `require("../audit")` or `import audit` to an example's files before its pin reaches the release that introduced those helpers (1.1.0) would `MODULE_NOT_FOUND` at runtime. Both examples are now pinned above that (`dev-container` 1.3.1, `claude-code` 1.2.0) and call the helpers; the constraint binds the next example added, or any repin that moves one *down*. `tests/integration/00-config-lint.test.sh` derives this per example from its actual pinned tag rather than a hardcoded list, so it keeps working unattended as each example upgrades in turn.

**cred-gateway's `access_log` requires the target directory to exist at container start, unlike the broker/proxy `AUDIT_LOG` env vars.** nginx opens every configured `access_log` file during startup and fails hard (`emerg`, refuses to start) if the directory is missing — there's no equivalent to the no-op-when-unset behavior `audit.js`/`audit.py` have, since nginx.conf is static and baked in. That's why `stack/cred-gateway/Dockerfile` bakes in an empty `/var/log/audit` even though the real content lives on the mounted volume.

## Tests

Two tiers behind one facade. `tests/run.sh` dispatches to `tests/<tier>/run.sh` and passes the remaining arguments through.

- `tests/integration/` — the security boundaries, against stubs and fixtures. No credentials, free, ~60s. `00-config-lint.test.sh` needs no docker.
- `tests/e2e/` — the paths a stub cannot reach (HTTPS/CONNECT, CA cert lifecycle, `git push` through the credential helper), against a **dedicated** GitHub App and `~/.config/agent-creds-e2e`. Spends real API quota.

A bare `tests/run.sh` runs integration only — e2e must be asked for by name (`tests/run.sh e2e`, or `all` for both, fail-fast). `lib.sh` and `fixtures/` are shared. See `tests/README.md`.

## Adding a new credential provider

The mechanics — which file goes where, restart order, generation-time constraints like host-matching and exact-match locations — are documented once, for maintainers and end-users alike, in `PLAYBOOK.md` under "Adding a credential provider to an existing stack". Follow that rather than duplicating it here.

Maintainer-only steps on top of it, when the provider is being added to `stack/` itself rather than an end-user's deployment:

1. Add a credential file path env var under `broker` in the relevant `compose.yaml`.
2. Add coverage in `tests/` — at minimum a spoofed-`Host` case proving the new addon does not inject for any host but the genuine one.

## Release process

Every release branch is cut from `main`, never from another release branch. Right after tagging `vX.Y.Z` on `main`, immediately cut both of the next branches it could need, so work always has a release branch to target instead of `main` directly — the standing branch is what makes "target the release branch, not main" the default instead of something to remember:

- `release/X.Y.(Z+1)` — the next patch. Cheap to create; makes it that much quicker to start a hotfix.
- `release/X.(Y+1).0` — the next minor.

Both branch off `main` at the tag. Feature/fix branches then target whichever release branch fits (`fix/*` off the patch branch, `feature/*` off the minor branch), not `main`.

When a release branch is ready:

1. Add a `CHANGELOG.md` entry directly on the release branch (see existing entries for format — this project versions the security boundary, not the code, so most entries need no "Upgrading" section).
2. Open a PR from the release branch into `main`, get it reviewed, merge it.
3. Tag `vX.Y.Z` on `main`.
4. **Sync forward only.** Merge `main` into every still-open release branch whose version is *above* the tag you just cut. Never merge it into one below. The direction is the whole rule:

   - **Above the tag — merge `main` in.** That branch will supersede this release, so it has to contain it. Skipping this is how a fix that lands via the patch branch never reaches the minor branch: the same "forgot where to land it" risk one level up, moved from branch-creation-time to release-time. This is what makes the standing-branch approach safe.
   - **Below the tag — it is overtaken, not dormant.** This project only moves forward; no older line is supported and nothing gets backported. Releasing a minor therefore does *not* mean syncing the previous minor's still-open branch: once `v1.4.0` is tagged, `release/1.3.2` has simply been passed, and merging `main` into it would only rebuild 1.4.0 under a patch number. Leave it where it is and retarget any work still aimed at it onto the current patch branch. (If an overtaken branch ever does need to ship, rebase its unique commits onto its own tag — `git rebase --onto v1.3.1 …` — never merge `main`.)

Most `release/*` branches here are inert: level with or behind `main`, carrying no unique commits, kept deliberately as markers of where a line was cut. Nothing needs doing to them, and by the rule above nothing ever should be.

Worked example from `v1.1.0` → `v1.1.1` — the above-the-tag case: `release/1.1.1` and `release/1.2.0` were cut from `main` right after tagging `v1.1.0`. A fix (`fix/dev-container-observer`) targeted `release/1.1.1`, not `main`. Once that PR merged into `release/1.1.1`, a CHANGELOG entry went straight on `release/1.1.1`, that branch PR'd into `main`, and `main` got tagged `v1.1.1`. Immediately after, `main` was merged into `release/1.2.0` — above `1.1.1`, so it had to carry the fix forward.
