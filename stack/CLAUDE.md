
## Commands

**Bring up the full stack (from repo root, outside the container):**
```bash
docker compose -f compose.yaml up --build
```

**Smoke test — run inside the dev container after opening in VSCode:**
```bash
./scripts/smoke-test.sh
```

**Logs:**
```bash
docker compose -f compose.yaml logs -f broker proxy cred-gateway
```

**Teardown (removes named volumes including the mitmproxy CA cert):**
```bash
docker compose -f compose.yaml down -v
```

**Rebuild and test a single service image:**
```bash
# From repo root (stack/ directory)
docker build -t test-broker broker
docker build -t test-proxy proxy
docker build -t test-cred-gateway cred-gateway
docker build -t test-dev dev
```

**Validate nginx config (config is baked into the image):**
```bash
docker build -t test-cred-gateway cred-gateway
docker run --rm test-cred-gateway nginx -t
```

**Recovery if setup.sh failed mid-run (idempotent, run inside dev container):**
```bash
/workspace/dev/setup.sh
```

**Restart a service after rotating a credential:**
```bash
docker compose -f compose.yaml up -d --force-recreate broker
docker compose -f compose.yaml up -d --force-recreate broker proxy  # for Anthropic key rotation
```

**Restart the proxy after editing the allowlist file:**
```bash
docker compose -f compose.yaml up -d --force-recreate proxy
```

**Force-regenerate the mitmproxy CA cert:**
```bash
docker compose -f compose.yaml down
docker volume rm agent-dev_proxy-certs
docker compose -f compose.yaml up -d
# Then: Dev Containers: Rebuild Container in VSCode
```

**Debug the proxy with a web UI (swap into proxy/Dockerfile CMD temporarily):**
```
mitmweb --web-host 0.0.0.0 --web-port 8081 --listen-host 0.0.0.0 --listen-port 8080 ...
```
And publish port 8081 in compose.yaml.
