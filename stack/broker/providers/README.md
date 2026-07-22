# Broker credential providers

This directory is **empty by design**, like `stack/cred-gateway/gateway.d/`.
The base broker image ships no credential routes — `server.js` loads every
`*.js` file it finds here at startup and dispatches by pathname, so a stack
with nothing mounted answers `404` on every credential path and `200` only on
`/healthz`.

Working references, both in `examples/claude-code/providers/`:

- [`github.js`](../../../examples/claude-code/providers/github.js) — mints an
  installation token from the App private key, caches it with a 5-minute safety
  window, and exposes it in three shapes: raw (`/github/token`, proxy only),
  `git credential` format (`/github/credential`), and identity for
  `git config` (`/github/identity`).
- [`anthropic.js`](../../../examples/claude-code/providers/anthropic.js) — the
  minimal case: read a credential from the environment, hand it to the proxy.

Wire it up in compose:

```yaml
broker:
  volumes:
    - ./providers:/app/providers:ro
```

Providers are discovered at startup only. After adding or editing one:

```bash
docker compose -f compose.yaml up -d --force-recreate broker
```

## Rules

- **A provider is reachable from the proxy, and from nothing else.** The broker
  sits on the `secure` network only. Adding a route here does not expose it to
  the dev container — that takes a matching `gateway.d` snippet, which you
  should add only when a dev-side *tool* must hold the credential locally.
- **Export the narrowest useful shape.** `github.js` exposes the raw token and
  the `git credential` form as separate routes precisely so the gateway can
  whitelist the second without the first. If a credential is only ever spent on
  an outbound API call, it needs no gateway snippet at all.
- **Mint scoped and short-lived where the vendor allows it.** The GitHub
  installation token expires in an hour; the Cloudflare provider mints a scoped
  token per profile. A long-lived key read straight off disk is the fallback,
  not the goal.
- **Do not route provider traffic through the proxy.** The broker calls
  `api.github.com` and `api.cloudflare.com` directly — the proxy fetches its
  credentials *from* the broker, so going the other way is circular.
- **Cache, and be explicit about how the cache ends.** `github.js` re-mints
  once the token is within 5 minutes of expiry; `cloudflare.js` caches per
  profile. Recovery from a *revoked* credential lives on the proxy side —
  `010_github.py` clears its own cache on a 401 — so a provider that caches
  forever has no way back. The deliberate exception is the lifetime-cached
  identity, which needs a broker restart if the App is renamed.

Adding a provider end to end — env var, provider file, proxy addon, tests — is
covered in the repo root [`CLAUDE.md`](../../../CLAUDE.md).
