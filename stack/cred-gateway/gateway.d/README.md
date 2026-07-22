# cred-gateway endpoint snippets

This directory is **empty by design**, like `stack/broker/providers/`. The base
cred-gateway image ships no provider endpoints — it serves `/healthz` and denies
everything else. Deployments supply the whitelist by bind-mounting a directory
of `*.conf` snippets here.

Working reference: [`examples/claude-code/cred-gateway/gateway.d/github.conf`](../../../examples/claude-code/cred-gateway/gateway.d/github.conf)
— the git credential-helper and identity endpoints, counterpart to that example's
`addons/010_github.py` and `providers/github.js`.

Each file is included inside the `server { }` block of the baked-in `nginx.conf`.
Wire it up in compose:

```yaml
cred-gateway:
  volumes:
    - ./gateway.d:/etc/nginx/gateway.d:ro
```

Apply changes with:

```bash
docker compose -f compose.yaml up -d --force-recreate cred-gateway
```

## Rules

- **Exact match (`location = /path`), never prefix match.** `location /github/`
  would expose every broker route under that prefix, including `/github/token`
  — which hands dev a raw installation token.
- **Only expose what a dev-side *tool* must hold locally** — credential helpers,
  identity for `git config`. If the credential is only ever spent on an outbound
  API call, it belongs in a proxy addon instead, so dev never sees it. This is
  why `/anthropic/key` and `/cloudflare/token` have no snippet here.
- **The mount source must sit outside whatever is mounted at `/workspace`.**
  Otherwise the agent can widen its own whitelist and wait for a restart. See
  the read-only shadow mount in `examples/dev-container/.devcontainer/compose.yaml`
  for how to handle the case where they unavoidably overlap.
- The `creds` rate-limit zone (10r/m, burst 5) is declared at `http` level in
  `nginx.conf` — reference it, don't redeclare it.
- Validate before restarting. `--add-host` is required: nginx resolves static
  `proxy_pass` upstreams at config-parse time, so a standalone `nginx -t` fails
  with `host not found in upstream "broker"` before it reports syntax errors.
  ```bash
  docker build -t test-cred-gateway stack/cred-gateway
  docker run --rm --add-host broker:127.0.0.1 \
    -v "$PWD/examples/claude-code/cred-gateway/gateway.d:/etc/nginx/gateway.d:ro" \
    test-cred-gateway nginx -t
  ```
  Same reason cred-gateway needs `depends_on: broker: condition: service_healthy`
  in compose — it will not start if broker DNS is unresolvable.
