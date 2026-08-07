# PLAYBOOK.md

Instructions for an AI agent — not a human reader — working in an
end-user's own project, to generate, extend, and upgrade a deployment of
the secure-agent-lab stack. This file does not assume the agent
has read this repo's `CLAUDE.md`, and it shouldn't: that file is scoped to
developing and maintaining this repo itself, not to using it. `README.md`
and `examples/` are for anyone to read; nothing here depends on them, but
browsing them is fine.

Fetch and follow this file at a pinned tag, e.g.:

```
https://raw.githubusercontent.com/lpezet/secure-agent-lab/refs/tags/vX.Y.Z/PLAYBOOK.md
```

The stack this playbook generates pins `stack/` at the same tag, the same
way `examples/*/compose.yaml` do (`...git#vX.Y.Z:stack/broker`).

## Before you start

Gather this from the end-user, asking whenever it isn't already clear —
don't guess:

- Which credential providers are needed: `github`, `anthropic` (Claude
  Code), `cloudflare`, other/custom.
- Where the stack should live in their project (e.g. `.devcontainer/`,
  `infra/agent-stack/`).
- Whether they want the `observer` dashboard.
- Which tag to pin to (default: latest release tag).

If a partial setup already exists in their project, adapt to it rather than
assuming a blank slate — use judgment, and ask the user if it's unclear
whether something already there should be kept, replaced, or extended.

## Known providers

Each of these ships as a **bank entry** under [`bank/`](bank/) — the files
themselves, plus a `provider.json` manifest declaring what they need. Install
one by copying it (see "A known provider" below); do not retype it from a
description.

| Provider | Injects into | Exposed to lab | Entry |
|---|---|---|---|
| GitHub | `api.github.com`, `uploads.github.com` | `/github/credential`, `/github/identity` | [`bank/github/`](bank/github/) |
| Anthropic | `api.anthropic.com` | nothing | [`bank/anthropic/`](bank/anthropic/) |
| Cloudflare | `api.cloudflare.com` | nothing | [`bank/cloudflare/`](bank/cloudflare/) |

Hosts, broker routes, env vars and secret files are **not** listed here — they
are in each entry's `provider.json`, which is the thing the lint checks against
the code. Duplicating them into prose is how the two drift.

What follows is the part a manifest cannot express: why each entry is shaped
the way it is. Read it before changing one.

### GitHub

- **Never match `github.com` in the addon** — only `api.` and `uploads.`. Git
  push/pull to `github.com` authenticates through the HTTPS credential helper
  (via `cred-gateway`), not header injection, and adding it here collides with
  git's own Basic-auth handshake inside the MITM'd tunnel.
- **Never expose `/github/token`** through cred-gateway. It is the raw
  installation token; the two exposed routes hand over a `git credential`
  response and an identity, not a reusable secret.
- **`credential.useHttpPath false` is deliberate.** Git otherwise puts the repo
  path in the credential lookup key, re-invoking the helper per path against a
  gateway route that is exact-match and path-agnostic. The App installation
  already scopes which repos are reachable. This is set by
  [`bank/github/lab/setup.sh`](bank/github/lab/setup.sh), which is also why
  that fragment is part of the entry rather than a step in this document.
- **`/github/identity` is cached for the broker's lifetime**, not on a TTL.
  Restart the broker if the App is renamed.
- **The audit trail records what an issued token can do**, not only that one
  was issued: `permissions` (the map of permission name to `read`/`write` the
  token carries) and `repository_selection` (`all` or `selected`). The App's
  installation grant is configured in GitHub's web UI, outside this stack —
  logging its scope is how "what can this lab currently do to GitHub?" becomes
  a question you answer by reading the trail instead of by opening GitHub
  settings. Repository *names* are deliberately not logged: `observer` serves
  the trail over HTTP, and the enum already answers whether the installation
  is org-wide.
- **This reports the ceiling; it does not lower it.** Only the deployer knows
  what scope their task actually needs, and inferring it from what the agent
  has been reaching for would ratify whatever it did. If the trail shows more
  authority than you expected, the fix is in GitHub's installation settings.

### Anthropic (Claude Code)

**Claude Code's active credential is usually an OAuth token, not an API key.**
A Claude subscription authenticates with `sk-ant-oat01-…` sent as
`Authorization: Bearer`, on a different rate-limit tier from an API key
(`sk-ant-api03-…`, sent as `x-api-key`). Both work; injecting the wrong one is
not an error, it silently bills and throttles differently. The entry handles
both — `ANTHROPIC_AUTH_TOKEN_PATH` wins over `ANTHROPIC_API_KEY_PATH`, so
switching to OAuth is a file change and nothing else. Both are `optional` in the
manifest precisely because exactly one of them is normally set.

- **The addon must use the `responseheaders` hook with
  `flow.response.stream = True`**, not `response`. Touching
  `flow.response.content` on a streamed response buffers the entire SSE body
  instead of passing chunks through live.
- **`/v1/organizations/*` (the Admin API) is blocked at the proxy**, so an
  attempt costs no quota.
- A deployment generated before 1.4.0 from `examples/dev-container` may still
  carry the older single `/anthropic/key` route with `x-api-key` injection. It
  keeps working but cannot use an OAuth token. Move it to the bank entry on the
  next reconciliation rather than leaving it — `check-drift.sh` will show the
  old file as having no counterpart.

### Cloudflare

- **The token is minted per named profile**, not read off disk. `X-Cf-Profile`
  hints which one; it is stripped before forwarding. Absent, the default is
  `workers-deploy`. Add profiles inside the broker provider, where the
  permission-group IDs live.
- **`CLOUDFLARE_API_TOKEN=proxy-injected` is a dummy** satisfying `wrangler`'s
  "am I authenticated" check. Never replace it with a real token.

## Generating a stack

Produce:

- A `compose.yaml` wiring `broker`, `proxy`, `cred-gateway`, `lab`, and
  (if requested) `observer` + `log-rotator`, each pinned to `stack/<service>`
  at the chosen tag.
- One directory per service, named after the service, holding only the
  content that gets bind-mounted into it — never the service's own
  Dockerfile/image files, those live in `stack/` at the pinned tag:
  - `broker/*.js` → `/app/providers` (one file per credential provider)
  - `proxy/*.py` → `/addons` (numbered, e.g. `010_github.py`, load order is
    alphabetical)
  - `cred-gateway/*.conf` → `/etc/nginx/gateway.d`
  - `lab/Dockerfile` extending `stack/lab`'s base image with any
    project-specific tools
- The two Docker networks: `secure` (broker + proxy + cred-gateway) and
  `lab` (lab + proxy + cred-gateway). The lab container is never on
  `secure`.
- `proxy/000_policy.py`, copied verbatim from `stack/proxy/addons/` at the
  pinned tag. The image ships no addons of its own — `/addons` exists only
  because the deployment mounts it — so an unvendored policy addon is not a
  stale control, it is a missing one, and nothing in the stack's health will
  say so.
- For each requested provider, the files described under "Known providers"
  above (or "A custom provider" below, for anything else).
- If `observer`/`log-rotator` are requested: no `networks:` entry for
  either — see the constraints below for why that's correct, not an
  omission.
**Egress is mediated by default.** The `lab` network ships `internal: true`, so
it has no default gateway and the proxy is the only route out. Without that,
`HTTP_PROXY` is only a request — `curl --noproxy '*'` leaves the container
untouched by any addon.

Opt out with `LAB_INTERNAL=false` when the lab needs tooling that cannot use an
HTTP proxy: raw sockets, `ssh`, anything resolving before it proxies. Proxied
HTTP and HTTPS are unaffected either way, because the **proxy** resolves the
hostname, not the client — so the symptom of a tool that needs the opt-out is
DNS failure inside the lab, not a proxy error.

Opting out costs egress mediation and nothing else: the broker stays unreachable
from the lab regardless, because that is `secure` network isolation, which this
flag does not touch. `scripts/check-invariants.sh` reports the opt-out as a
finding on every run, by design — a disabled control should not be silent.

- If egress filtering is requested (opt-in, off by default): copy
  `stack/proxy/addons/001_allowlist.py` in alongside `000_policy.py`, and
  mount the allowlist data file from a directory *other* than `proxy/` —
  that whole directory lands at `/addons`, so a non-addon file placed in it
  gets loaded as one:

  ```yaml
  volumes:
    - ./allowlist:/etc/agent-allowlist:ro
  ```

  With no such file mounted the addon permits every destination and logs a
  warning at startup, so a deployment that half-enables this fails open.
  One entry per line, `domain [METHODS]`, methods defaulting to
  `GET,HEAD,OPTIONS`; the addon's docstring has the full format.

Generation-time constraints that apply regardless of which provider is
being generated:

- Match `flow.request.host` in proxy addons, never
  `flow.request.pretty_host` — the latter is client-controlled and lets a
  spoofed `Host` header steal injected credentials or bypass the broker
  block.
- `cred-gateway` snippets must use exact-match `location = /path` blocks,
  never a prefix match — a prefix like `location /github/` exposes sibling
  routes that must stay broker-only.
- Expose a `cred-gateway` route only if lab tooling genuinely needs raw
  access to it — almost never. Raw provider tokens/keys must never be
  reachable from the lab container.
- The proxy's Dockerfile must not add `USER mitmproxy` — the base image's
  entrypoint needs to run as root initially to `usermod` the `mitmproxy`
  user before dropping privileges via `gosu`.
- The broker calls provider APIs directly, never through the proxy —
  routing through the proxy would be circular (the proxy needs the broker
  to authenticate its own outbound calls).
- Credentials are **files**, never environment variables. Each one lives in
  the host directory bind-mounted read-only at `/secrets` (conventionally
  `~/.config/agent-creds/`), and the broker learns its location from a
  `*_PATH` env var — `GITHUB_APP_PRIVATE_KEY_PATH: /secrets/github-app.pem`,
  `ANTHROPIC_API_KEY_PATH: /secrets/anthropic.key`. A value passed as an env
  var instead is readable via `docker inspect` and `/proc/<pid>/environ`,
  leaks into any process dump or crash report, and tends to end up committed
  in a `.env`. Follow the same convention for custom providers.
- If a lab-side CLI tool needs a placeholder credential to pass its own
  "am I authenticated" check (e.g. `gh`, `wrangler`), use an obvious dummy
  value and let the proxy inject the real one at the wire level — never
  put a real credential in the lab container's environment.
- `observer` and `log-rotator` must have no `networks:` entry at all —
  that's what keeps them off `secure` and `lab` (Compose's implicit
  `default` network ends up containing only the two of them, since every
  other service declares an explicit `networks:` list). Do not "fix" this
  by adding one.

### Audit logging, `observer` and `log-rotator`

Only if the end-user asked for it. All three services write JSONL to one
shared named volume; `observer` reads it, `log-rotator` keeps it bounded
and is what makes the volume writable at all:

```yaml
services:
  broker:
    volumes:
      - audit-logs:/var/log/audit
    environment:
      AUDIT_LOG: /var/log/audit/broker.jsonl

  proxy:
    volumes:
      - audit-logs:/var/log/audit
    environment:
      AUDIT_LOG: /var/log/audit/proxy.jsonl

  # No AUDIT_LOG — nginx.conf is baked into the image and always writes
  # /var/log/audit/cred-gateway.jsonl. The mount is all that's needed.
  cred-gateway:
    volumes:
      - audit-logs:/var/log/audit

  # Live view on :9000. Read-only, holds no credentials, loopback-published
  # so it's viewable from the host but not from inside the stack.
  observer:
    build: https://github.com/lpezet/secure-agent-lab.git#vX.Y.Z:stack/observer
    volumes:
      - audit-logs:/var/log/audit:ro
    ports:
      # Env-indirect, not a literal: one Compose project per stack means two
      # stacks on one host collide on port allocation otherwise.
      - "127.0.0.1:${OBSERVER_PORT:-9000}:9000"
    restart: unless-stopped

  # Not optional if anything above is enabled — see below.
  log-rotator:
    build: https://github.com/lpezet/secure-agent-lab.git#vX.Y.Z:stack/log-rotator
    volumes:
      - audit-logs:/var/log/audit
    restart: unless-stopped

volumes:
  audit-logs:
```

Neither `observer` nor `log-rotator` gets a `networks:` entry — see the
constraint above.

`log-rotator` is not just log hygiene, and dropping it to "add rotation
later" breaks audit logging outright. broker runs as `node` and proxy as
`mitmproxy` — two different non-root uids writing into the same directory
— and its entrypoint `chmod 1777`s that directory on every start, as root,
which is also what lets it `copytruncate` files regardless of which uid
created them. It runs as root deliberately; nothing else in the stack does.

If `observer`'s `9000` is already taken on the host, set `OBSERVER_PORT` in
that deployment's `.env` — change the host side only, never the container
side.

**Mounting the volume is not the same as producing a trail.** `audit.js` and
`audit.py` are libraries, not interceptors: cred-gateway logs every request
because its nginx config is baked into the image, but the broker and proxy
log only what their provider and addon files explicitly call. A stack with
custom providers that don't call the helpers gets a dashboard that looks
complete while its custom traffic is entirely invisible — nothing errors,
the events simply never exist. Whenever you add a provider or addon, add the
`logEvent`/`log_event` calls described under "A custom provider" in the same
edit.

**What is safe to log — and who guarantees it.** The trail is a plaintext
file on a shared volume that `observer` renders over HTTP, so a credential
written into it has left the boundary the rest of this stack exists to
maintain. Note where that responsibility sits: the images contribute no
events of their own, so every line in the trail was written by a provider or
addon file *this deployment owns*. `observer` is exactly as leak-free as
those files are, and nothing upstream of it can make an unsafe event safe.
It is the one component whose security you inherit rather than receive.

So log values you chose yourself: host, method, provider, decision,
credential *type*, and any identifier you parsed out. Anything you did not
construct — request or response headers, bodies, query strings, exception
messages — is free text from somewhere else, and belongs on stdout, which is
not the volume `observer` serves.

Paths need a judgement call, because some providers put the credential in
the URL rather than a header — Telegram's is `/bot<TOKEN>/<method>`, and
`?access_token=` query strings are the same shape. Two things make the raw
path riskier than it looks: **mitmproxy's `flow.request.path` includes the
query string**, so "I only logged the path" is not the guarantee it sounds
like, and a path segment that is safe today can start carrying an id or a
token when the provider adds an endpoint. Parse out the part you actually
want:

Strip the query string *before* splitting, not after. Getting that order
wrong is the whole hazard in miniature: on
`/bot<TOKEN>/sendMessage?chat_id=…&text=…`, a bare `split("/")[2]` returns
`sendMessage?chat_id=…&text=…` — the recipient and the message body, written
into the trail as if it were a method name. The token itself is in segment
1 and stays out, which is exactly why the mistake survives review.

```python
# Telegram: /bot<TOKEN>/<METHOD>?<params> — never log the path itself.
# split("?") first: flow.request.path carries the query string, so splitting
# on "/" alone puts it inside the last segment.
parts = [p for p in flow.request.path.split("?", 1)[0].split("/") if p]
api_method = parts[1] if len(parts) > 1 else "?"
audit.log_event("cred_injected", provider="telegram", api_method=api_method)
```

Indexing defensively matters too — an addon that raises on a malformed path
takes the request down with it, and a path short enough to break `parts[1]`
is exactly what a prober sends.

The shipped addons do this too — see `_endpoint()` in `020_anthropic.py`,
which drops the query string and keeps the first two segments, so the trail
records `/v1/messages` rather than `/v1/messages/batches/<id>?beta=…`. Copy
that shape, but pick the slice for *your* provider: the segments that are
safe to keep are exactly what differs between Anthropic and Telegram, which
is why there is no shared helper for it in `audit.py`.

Logging the raw path is defensible for a provider that authenticates by
header only and has no ids in its URLs — but establish that it is that kind
of provider before deciding, and default to parsing if unsure. The parsed
form costs one function and never has to be revisited when the provider
grows an endpoint that carries something.

**Log the refusals, not just the successes.** Every error return needs an
event too — a missing credential file, an unparseable one, a provider API
that returned 401, a request the addon blocked. A trail that records only
what worked is worse than misleading during an incident: absence of an event
reads as "never happened" when it means "happened, and was refused." Name
the failure with a value you defined — a reason string of your own, or the
exception's `code`/`name` — rather than quoting its message, which is the
same free text the rule above is about.

### Last step: record the provenance

Write a small stub `CLAUDE.md` at the root of wherever the stack was
generated (e.g. `.devcontainer/CLAUDE.md`), pointing back at this file's URL
for anything future related to this stack. This keeps the reference scoped
to that subdirectory instead of bloating the end-user's top-level
`CLAUDE.md`.

Record four things in it, not just the pin. Nothing else in the deployment
preserves them, and step 3 of "Upgrading" cannot be carried out without the
first two — a future agent otherwise has to guess which example the
bind-mounted files came from, and after enough local divergence that is no
longer visible by inspection:

```markdown
Stack: secure-agent-lab, pinned v1.3.0
Generated from: examples/claude-code
Reconciled: proxy/ v1.3.0 · broker/ v1.3.0 · cred-gateway/ v1.3.0
Custom (no upstream counterpart, never reconciled): proxy/030_fal.py, broker/fal.js
Playbook: https://raw.githubusercontent.com/lpezet/secure-agent-lab/refs/tags/v1.3.0/PLAYBOOK.md
```

The `Reconciled:` line is the one that earns its keep on upgrade: it gives
step 3 a "from" as well as a "to", so a directory that was skipped in an
earlier upgrade stays visible instead of silently inheriting the new pin.
Update it as part of the upgrade, not after.

## Adding a credential provider to an existing stack

### A known provider

Copy the files, do not retype them. `<name>` is a directory under
[`bank/`](bank/); everything the install needs is in its `provider.json`.

1. **Check the pin.** If the entry's `min_stack` is above the tag your
   `compose.yaml` builds from, stop — the install will look fine and fail at
   runtime with `MODULE_NOT_FOUND` on `require("../audit")`. Repin first.
2. **Copy** `bank/<name>/broker/<name>.js` → your `broker/`, and
   `bank/<name>/cred-gateway/<name>.conf` → your `cred-gateway/` if the entry
   has one.
3. **Copy the addon with a prefix**: `bank/<name>/proxy/<name>.py` → your
   `proxy/NNN_<name>.py`. Pick the lowest unused multiple of ten in the entry's
   `load_band` — `provider` means 010–899. The bank ships no prefix because the
   number is yours, not the entry's: two providers both wanting `030` would
   otherwise be your problem to discover.
4. **Secrets**: for each `secrets[]` entry, put the value in a file at
   `<secrets-dir>/<file>` mode `0600` and add `<env>: /secrets/<file>` to the
   broker's `environment:`.
5. **Config**: for each `config[]` entry, add `<env>=` to `.env`.
6. **Lab environment**: merge `lab_env` into the lab service's `environment:`.
   These are literals — `proxy-injected` and URLs. A real credential here is a
   bug, and `tests/integration/00-config-lint.test.sh` fails on one.
7. **Lab setup**: if the entry has `lab_setup`, copy it into your `lab/` and
   make sure your `setup.sh` runs it.
8. **Allowlist**: append the entry's `hosts` to `/etc/agent-allowlist` if you
   use one.
9. **Restart, then verify**:
   ```bash
   docker compose up -d --force-recreate broker proxy cred-gateway
   ```
   then run the matching check from "Verifying the stack" below.

Record what you installed in `.sal/installed.json` — name, assigned `NNN`,
files written — so `check-drift.sh` compares exactly those entries rather than
falling back to guessing which example you started from. Without it, drift
still resolves by filename, which works but degrades on a deployment carrying
many custom files.

### A custom provider

**You own a custom provider permanently.** It is bind-mounted, so no
upstream release will ever change it and the "diff against the new tag"
step under "Upgrading" has nothing to compare it to. When a `CHANGELOG`
entry describes a fix to an addon or provider, the fix applies to your
custom ones too and you have to port it by hand. Say so to the end-user at
the time you add one — that is the deal they are accepting.

**Start from the closest bank entry.** Copy `bank/<nearest>/` and edit it,
rather than writing from this description. Every entry already has the host
matching, the strip-before-fetch ordering, the bounded endpoint label and the
audit calls in the right shape — which is the whole reason they exist, because
each of those has been got wrong here at least once. Pick by resemblance:
`anthropic` for "read a credential, inject a header", `cloudflare` for "mint
something scoped per call", `github` for "the lab also needs a helper".

Then, for anything the bank does not cover:

**Broker** — add a file to the project's `broker/` directory (bind-mounted
to `/app/providers`). Reads a credential from an env-var-specified path
under `/secrets`, exposes a route, dispatches on pathname. Pick it up with
`docker compose up -d --force-recreate broker`. Log significant events via
the baked-in `audit.js` (`require("../audit").logEvent(...)`) — a provider
that calls nothing produces no trail at all, so add the calls in the same
edit as the provider, and see "What is safe to log" above for what may go
in them.

**Proxy** — add a numbered file to the project's `proxy/` directory
(bind-mounted to `/addons`, loaded alphabetically — pick a prefix that
puts it after `000_policy.py`). Match `flow.request.host` against the
exact provider hostname, strip whatever the client sent, then fetch a
token from the broker route added above and inject it. Strip *before*
fetching, and never in the same statement as the injection: the fetch
raises when the broker is unreachable, and a strip that happens after it
(or inside the same assignment) does not happen at all — forwarding the
agent's own credential to the provider, which is the opposite of the
point. Cache with a short TTL. Pick it
up with `docker compose up -d --force-recreate proxy` — `entrypoint.sh`
auto-discovers `*.py` at startup. Use the baked-in `audit.py`
(`import audit; audit.log_event(...)`) the same way.

**Cred-gateway** — only if lab tooling needs raw access to something the
broker/proxy path doesn't cover (rare). Add an exact-match snippet to the
project's `cred-gateway/` directory (bind-mounted to
`/etc/nginx/gateway.d`), proxying to a broker route. Pick it up with
`docker compose up -d --force-recreate cred-gateway`.

Use `up -d --force-recreate <service>` rather than `restart` throughout —
it's what the rest of this project's docs use, and it recreates the
container against the current `compose.yaml` instead of restarting the
process inside the existing one.

## Upgrading

**Read this before bumping a tag.** A deployment is versioned in two halves
and only one of them moves when you repin. `compose.yaml` builds each
service's *image* from `stack/<service>` at the pinned tag — but the files
that actually enforce the security boundary (`proxy/*.py`, `broker/*.js`,
`cred-gateway/*.conf`) are bind-mounted from the deployment's own
directories and **shadow whatever the image ships**. Bumping the tag
upgrades the images and leaves those files byte-for-byte as they were.

That is the failure mode to design the upgrade around: a stack can be
running images that carry a security fix while the vulnerable addon sits
bind-mounted right next to them, with nothing in `docker compose ps` or a
healthcheck to show for it. Step 3 below is the point of the upgrade, not
paperwork.

1. Bump the pinned tag in `compose.yaml` (and in the stub `CLAUDE.md`'s
   recorded pin) to the new tag.
2. Read this repo's `CHANGELOG.md` for **every** entry between the old and
   new tag, not just the newest one, and apply anything listed under that
   entry's "Upgrading" section. Manual steps in a skipped intermediate
   release still apply.
3. Diff every bind-mounted file against the new tag and port the
   differences in by hand.

   `scripts/check-drift.sh` does the comparison for you, including the
   counterpart resolution the rest of this step describes. It needs nothing
   but bash, git and diff, and it reads the deployment's own pin and
   provenance stub:

   ```bash
   # From a checkout of this repo, against your deployment directory:
   scripts/check-drift.sh --to "$NEW" /path/to/deployment
   scripts/check-drift.sh --to "$NEW" --show-diff /path/to/deployment  # with hunks
   ```

   It exits non-zero on drift or a missing `000_policy.py`, so it also works
   as a pre-upgrade gate in CI. Custom providers are reported as `custom`
   and don't drift-fail — they can't drift, having nothing to drift from.

   **They are still checked.** `check-drift.sh` now also runs
   `scripts/check-invariants.sh`, which asks the other question: is each file
   safe *on its own terms*? That needs no upstream, no tag and no network, so
   it reaches exactly the files the diff cannot — the ones you wrote. It is
   also runnable alone:

   ```bash
   scripts/check-invariants.sh /path/to/deployment
   ```

   A findings-free scan is **not** a pass. These are greps against a known
   list; a provider can be unsafe in ways none of them anticipate, and
   "What is safe to log" below is the standard. Set `SKIP_INVARIANTS=1` to
   run drift alone.

   The rest of this step is what the script automates, and what to do by
   hand if you're upgrading *from* a tag before 1.4.0 that doesn't ship it.
   Most upstream counterparts live under `examples/` —
   `stack/broker/providers/` and `stack/cred-gateway/gateway.d/` hold only a
   README, since content is what the deployment supplies.
   `stack/proxy/addons/` is the exception and needs a second diff of its
   own, below:

   Which example is the counterpart is recorded in the stub `CLAUDE.md`'s
   `Generated from:` line (see "Last step: record the provenance"). Don't
   guess if it's missing — the examples have diverged from each other, so
   the wrong one reports real upstream files as drift. Diff against both and
   take the closer match, then write the answer into the stub for next time.

   ```bash
   NEW=vX.Y.Z
   git clone --depth 1 --branch "$NEW" \
     https://github.com/lpezet/secure-agent-lab.git /tmp/sal-$NEW
   REF=/tmp/sal-$NEW/examples/claude-code   # per the stub's `Generated from:`
                                            # dev-container's is .devcontainer/

   diff -ru proxy/        "$REF/proxy/"
   diff -ru broker/       "$REF/broker/"
   diff -ru cred-gateway/ "$REF/cred-gateway/"
   ```

   Then diff the addons whose upstream home is `stack/proxy/addons/` rather
   than `examples/`. The `examples/` copies are incomplete: every example
   vendors `000_policy.py`, none vendors `001_allowlist.py`, so a deployment
   that enabled egress filtering sees its allowlist addon reported as
   `Only in proxy/` — indistinguishable from a custom provider, and step 4
   would then have you treat an upstream file as ownerless:

   ```bash
   diff -u proxy/000_policy.py    "/tmp/sal-$NEW/stack/proxy/addons/000_policy.py"
   diff -u proxy/001_allowlist.py "/tmp/sal-$NEW/stack/proxy/addons/001_allowlist.py"
   # Both should match exactly. A diff in either is a finding, not a
   # customization — these are upstream's files, vendored.
   ```

   Note what this is *not*: the proxy image does not ship these addons and
   the mount does not shadow them. `stack/proxy/Dockerfile` bakes in only
   `entrypoint.sh` and `audit.py`; `/addons` exists solely because the
   deployment mounts it, and `entrypoint.sh` loads whatever `*.py` it finds
   there. So a policy addon that was never vendored isn't a stale copy
   hiding under a mount — it is a control that does not exist, with a
   healthy-looking proxy in front of it.

   Diff from the tag each directory was last reconciled against, not from
   the tag `compose.yaml` happened to be pinned at — they differ whenever an
   earlier upgrade skipped this step, which is exactly the case worth
   catching. Expect legitimate divergence too: a deployment drops providers
   it doesn't use and adds ones upstream doesn't ship. Read every hunk and
   decide; don't overwrite wholesale. Update the stub's `Reconciled:` line as
   you go.
4. Custom providers have no upstream counterpart, so step 3 says nothing
   about them and no upstream fix has ever reached them. Re-read each one
   against the generation constraints under "Generating a stack" — in
   particular that it matches `flow.request.host` and never
   `flow.request.pretty_host`.
5. Rebuild, recreate, and confirm the images actually moved:

   ```bash
   docker compose build --pull
   docker compose up -d --force-recreate
   docker compose images            # image IDs must differ from before
   ```

   **`restart` and a bare `up -d` will both silently skip the upgrade.**
   Neither rebuilds: the image is tagged `<project>-<service>` and already
   exists locally, and Compose builds only when an image is missing unless
   you ask it to. A changed git-URL tag in `build:` is not enough on its own
   — you get the old image in a freshly recreated container, with nothing in
   `docker compose ps` to show for it. That is the same class of silent
   no-op as the bind-mount trap above, from the other direction, which is
   why `docker compose images` is part of the step rather than optional
   diligence.
6. Re-run "Verifying the stack" below. After an upgrade it is the gate, not
   a smoke test.

## Verifying the stack

Run these against the live `docker compose` stack after generating or
changing anything (adjust service names below if the generated
`compose.yaml` names them differently than `lab`, `broker`, `proxy`,
`cred-gateway`, `observer`).

**All services healthy:**

```
docker compose ps
```

Every service should be `running`/`healthy`, none restarting.

**Broker is unreachable from the lab container** — the core security
boundary, since `lab` is not on the `secure` network:

```
docker compose exec lab getent hosts broker                              # should fail to resolve
docker compose exec lab curl -sS --max-time 3 http://broker:8080/healthz # should fail to connect
```

Both failing is the pass condition; either succeeding means the network
boundary is broken.

**`cred-gateway` only serves whitelisted routes:**

```
docker compose exec lab curl -s -o /dev/null -w '%{http_code}\n' http://cred-gateway/definitely-not-a-real-path
# expect 403

docker compose exec lab curl -s -o /dev/null -w '%{http_code}\n' http://cred-gateway/github/identity
# expect 200, only if github is configured
```

**Each configured provider works end-to-end through the proxy**, using
whatever client the lab container already has for it:

```
docker compose exec lab gh api /rate_limit   # github
docker compose exec lab wrangler whoami      # cloudflare
```

For Anthropic, the check is Claude Code (or whatever agent harness runs in
the lab container) successfully making one real request — there usually
isn't a separate CLI to probe with.

**A spoofed `Host` header does not talk the proxy into forwarding to the
broker.** Plain HTTP through the proxy, so no certificate handling — and the
second server the spoof needs to point at is one the stack already has:

```
docker compose exec -T lab curl -s --max-time 8 --proxy http://proxy:8080 \
  -H 'Host: api.anthropic.com' http://broker:8080/anthropic/cred
# expect {"error":"internal host blocked by proxy policy"} — a 403 from 000_policy.py
```

A credential in that response body, or anything that looks like a broker
reply, means an addon is matching `flow.request.pretty_host` and the whole
injection boundary is open. Swap `/anthropic/cred` for any broker route the
deployment actually has; the route barely matters, since a correct stack
never reaches it.

**The Admin API block holds** (only if Anthropic is configured):

```
docker compose exec -T lab curl -s https://api.anthropic.com/v1/organizations/me
# expect {"error":"Admin API blocked by proxy policy"} — 403 from 020_anthropic.py,
# blocked at the proxy, so it costs no quota
```

**The egress allowlist denies an unlisted destination** — only if the
deployment mounts one. `001_allowlist.py` is opt-in, and with no
`/etc/agent-allowlist` file present every destination is permitted, so this
check passes vacuously on a stack that never enabled it:

```
docker compose exec -T lab curl -s --proxy http://proxy:8080 http://neverallowed.example.com/
# expect {"error":"destination blocked by allowlist policy"}
```

What the checks above **don't** cover is per-addon spoof resistance — a
spoofed `Host` pointing at a genuine vendor hostname, where the question is
whether the addon injects into a request bound somewhere else. That needs a
second external server to legitimately receive it, which is more setup than
a smoke check warrants; this repo's `tests/integration/20-proxy-policy.test.sh`
and `25-proxy-injection.test.sh` cover it against stub servers. Treat that
specific case as covered by construction (the "match `flow.request.host`"
constraint above), and the broker check above as the live proof that the
constraint was actually followed.
