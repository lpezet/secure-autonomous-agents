# Regression suite

Guards the security boundaries this repo exists to enforce: the dev container
must never obtain a raw credential, and the proxy must never spend one on a
destination the operator did not intend.

```bash
tests/run.sh              # everything (~60s once images are cached)
tests/run.sh 00           # one suite
tests/run.sh 10 20        # several
FORCE_BUILD=1 tests/run.sh   # rebuild images instead of reusing cached ones
```

Exit code is non-zero if any suite fails.

## No credentials required

Every suite runs against stubs and fixtures. The broker is replaced by an nginx
container that echoes `BROKER-HIT <uri>`, or — in the injection suite — hands
out the fake credential `LEAKED-CREDENTIAL-MARKER`, so a leak shows up as a
marker string instead of a real key. Nothing reads `~/.config/agent-creds` and
nothing calls GitHub, Anthropic or Cloudflare.

Containers, networks and temp files are named with the running PID and removed
by an `EXIT` trap, so a run never collides with a real stack you have up.

## Suites

| | Needs docker | Covers |
|---|---|---|
| `00-config-lint` | no | Static invariants: exact-match locations only, no raw-credential endpoint in any snippet, dummy `proxy-injected` values intact, no committed key material, `010_github.py` still not matching `github.com`, `000_policy.py` first in load order |
| `10-cred-gateway` | yes | Whitelist behaviour: allowed paths reach the broker, denied paths 403, path-normalisation probes (`..`, `%2f`, case, trailing slash), rate limiting, multi-snippet composition, snippets read-only in-container, and that a prefix-match snippet really does leak `/github/token` |
| `20-proxy-policy` | yes | `000_policy.py` blocks `broker` and `cred-gateway` across methods and paths, and cannot be bypassed with a spoofed `Host` header |
| `25-proxy-injection` | yes | `010_github` / `020_anthropic` / `030_cloudflare` inject only for the genuine vendor host; a spoofed `Host` cannot redirect a credential to another server; Anthropic Admin API stays blocked |
| `30-proxy-allowlist` | yes | Permissive without a file, default-deny with one; per-domain method sets, wildcard matching (and non-matching of sibling domains), inline comments, no spoofing bypass |
| `40-broker` | yes | `/healthz`, 404 on unknown routes, provider auto-discovery from `PROVIDERS_DIR`, non-`.js` files ignored, no providers baked into the image, runs as non-root |
| `50-mount-isolation` | yes | `examples/dev-container` mounts `../` read-write; the nested read-only bind must keep `addons/`, `providers/`, `gateway.d/` and `compose.yaml` unwritable while the project stays writable |

## Writing a test

Source `lib.sh` and use `check`, `check_contains`, `check_not_contains`, then
`finish`. Helpers: `net_up`, `curl_up`, `stub_broker_up [aliases...]`,
`http_code`, `http_body`, `wait_http`, `build_image`, `track_container`.

`curl_up` starts one long-lived curl container and every request goes through
`docker exec` — roughly 50ms per assertion versus ~1s for `docker run`.

Two things that bite:

- **Capturing a shell error from a container.** `docker run … sh -c "cmd 2>&1"`
  does not capture "Read-only file system" — that message comes from the shell,
  not from `cmd`. Put the redirect on `docker run` itself.
- **Rate-limit assertions need a fresh container.** The `creds` zone keys on
  client address and refills at 1 request per 6s, so earlier assertions in the
  same suite eat the budget.

## Known environment quirk

Docker Desktop on WSL writes `"credsStore": "desktop.exe"` into
`~/.docker/config.json`. `docker build` invokes that helper even for public
images and it is often not executable from inside the distro:

```
error getting credentials — fork/exec …/docker-credential-desktop.exe: exec format error
```

`docker run` and `docker pull` are unaffected, which makes it look intermittent.
`lib.sh` detects an unusable store and points `DOCKER_CONFIG` at a scratch
config for the run; it leaves a working store alone.

## What is not covered

- The real credential path end to end. Exercising `git push` with a live
  installation token needs `GITHUB_APP_ID` / `GITHUB_APP_INSTALLATION_ID` and a
  real App key. `stack/scripts/smoke-test.sh`, run inside the dev container,
  is still the check for that.
- HTTPS/CONNECT flows. Everything here is plain HTTP through the proxy. The
  addons make their host decision before any TLS handling, so the logic under
  test is the same, but the TLS path itself is unexercised.
- The mitmproxy CA cert lifecycle and `setup.sh` / `setup-start.sh`.
