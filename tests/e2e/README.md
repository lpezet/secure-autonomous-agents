# e2e tier

The whole stack, real credentials, real vendor APIs.

```bash
tests/run.sh e2e          # via the facade
tests/e2e/run.sh          # or directly
tests/e2e/run.sh 20       # only suites starting with 20
KEEP_STACK=1 tests/e2e/run.sh   # leave the stack up afterwards to poke at
```

Without credentials configured this **skips** (exit 0) and tells you what is
missing, so it is safe in a pipeline that does not have them. It never fails
for being unconfigured.

## Why this exists

[`../integration/`](../integration/README.md) covers the security boundaries
thoroughly and for free, so this tier only earns its keep on the paths a stub
cannot reach:

- **HTTPS / CONNECT.** Every integration request is plain HTTP. Here the proxy
  terminates a real TLS tunnel with its own CA, which exercises the cert trust
  chain, `update-ca-certificates`, and the `proxy-certs` volume.
- **`git push` through the credential helper.** `010_github.py` deliberately
  does not match `github.com`, so pushing authenticates through `git
  credential` → cred-gateway → broker — a path nothing else touches. It can
  break while every other test stays green.
- **The broker's real provider code.** JWT signing, the GitHub token exchange,
  the caches. Integration tests the loader; this tests the providers.
- **SSE passthrough.** A stub cannot show you whether a response buffered.
- **The vendors' own auth.** An injected credential that the API rejects is
  still a failure, and only a real call finds it.

It also re-runs the boundary assertions against a broker that is genuinely
holding secrets. Same checks, real stakes.

## Setup

**1. A dedicated GitHub App.** Not the one your agent uses. Create it, install
it on one throwaway repository, download the private key.

```bash
mkdir -p ~/.config/agent-creds-e2e
cp ~/Downloads/<your-test-app>.private-key.pem ~/.config/agent-creds-e2e/github-app.pem
chmod 600 ~/.config/agent-creds-e2e/github-app.pem
```

**2. `.env`.**

```bash
cp tests/e2e/.env.example tests/e2e/.env
$EDITOR tests/e2e/.env
```

The Anthropic credential goes in `.env`, not in the creds directory — the
reference `providers/anthropic.js` reads it from the environment. Only
`github-app.pem` is a file.

Override the directory with `AGENT_CREDS_DIR` if you keep it elsewhere.
`run.sh` refuses outright to run against `~/.config/agent-creds`: this tier
mints tokens, pushes commits and burns quota, and doing that with the App a
real agent depends on turns a test bug into a production incident.

## The stack under test

`compose.yaml` here, **not** `examples/claude-code/compose.yaml` — that one
builds from `github.com/…#main`, so running it would certify whatever is on
`main` rather than the tree you are about to ship. Every build here is a local
path.

The addons, providers and gateway snippets are bind-mounted straight out of
`examples/claude-code/`, so this exercises the reference implementation the
repo ships and cannot drift from a copy of it.

Two additions a real deployment does not have: an `echo` service aliased to
`attacker-host`, which reflects request headers so a test can see what the
proxy sent and to whom; and `command: sleep infinity` on `dev`, since there is
no devcontainer lifecycle to hold it open. `run.sh` performs the two steps
`setup.sh` would have done — trusting the CA and wiring the credential helper.

## Suites

| | Covers |
|---|---|
| `10-boundary` | Broker unresolvable and unroutable from dev, no tunnel through the proxy (including with a spoofed `Host`), cred-gateway allows exactly two paths, dummy env values intact, nothing credential-shaped in dev's environment or git config |
| `20-injection` | Anthropic and GitHub over real HTTPS with no credential in the request, SSE not buffered, Admin API blocked, and the pre-fix exploit — claim to be the vendor, deliver to your own server — leaking nothing |
| `30-git` | Identity from the broker, clone over HTTPS via the credential helper, no token persisted into `.git/config`, push a scratch branch, verify it landed, delete it |

## Cost and side effects

Each run makes two small Anthropic calls (haiku, ≤32 output tokens), a handful
of GitHub API calls, and — if `E2E_TEST_REPO` is set — pushes one empty commit
on a scratch branch named `e2e-<timestamp>-<pid>` and deletes it again. The
delete runs from an `EXIT` trap, so it still happens if an assertion fails
partway.

## Never print a secret

`check_no_secret` (in `../lib.sh`) is the assertion to use whenever the value
under test could be live. `check_not_contains` writes its haystack to the
terminal on failure, which for these suites means dumping a real key into your
scrollback and any CI log. `check_no_secret` reports the matching pattern and a
byte offset and nothing else.

Match credential *shapes* — `sk-ant-…`, `ghs_…`, `v1.<hex>` — via
`SECRET_PATTERNS`, so a suite never has to hold the secret it asserts about.

## What is still not covered

- Cloudflare. The `claude-code` example has no `030_cloudflare.py`; the
  addon has integration coverage only.
- The devcontainer lifecycle itself. `run.sh` reimplements the two essential
  steps of `setup.sh` rather than running it, so a regression in those scripts
  would not show up here.
- The TLS form of the Host-spoofing attack. The exploit is reproduced over
  plain HTTP through the proxy, which is how it was originally found; the
  addons make their host decision before any TLS handling, so the code under
  test is the same, but a CONNECT-tunnelled variant is not exercised.
