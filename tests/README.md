# Tests

Two tiers, split by whether the credentials involved are real.

```bash
tests/run.sh                     # integration — the safe default
tests/run.sh integration 20 30   # → tests/integration/run.sh 20 30
tests/run.sh e2e                 # → tests/e2e/run.sh
tests/run.sh all                 # both, integration first
```

`tests/run.sh` is a thin facade: it picks a tier and passes every remaining
argument through, so `tests/run.sh 20` still means "integration, suite 20" and
`FORCE_BUILD=1` still works. Each tier's `run.sh` is equally runnable on its
own.

| Tier | Credentials | Cost | Covers |
|---|---|---|---|
| [`integration/`](integration/README.md) | none — stubs and fixtures | free, ~60s | The security boundaries: whitelist behaviour, proxy host matching, egress allowlist, mount isolation |
| [`e2e/`](e2e/README.md) | real, from a dedicated App and creds dir | real API quota | The paths a stub cannot reach: HTTPS/CONNECT, the CA cert lifecycle, `git push` through the credential helper, live token minting |

A bare `tests/run.sh` deliberately does not run e2e. That tier spends real API
quota, mints real tokens and pushes to a real repository — it should be
something you ask for by name, not something the obvious command does to you.
For the same reason `all` is fail-fast: if integration is red there is no point
paying for e2e.

## Shared code

`lib.sh` holds the assertions (`check`, `check_contains`, `check_not_contains`,
`ok`, `ko`, `skip`, `suite`, `finish`) and the docker helpers (`net_up`,
`curl_up`, `stub_broker_up`, `http_code`, `http_body`, `wait_http`,
`build_image`, `track_container`). Both tiers source it; `fixtures/` is shared
the same way.

Every resource is named with the running PID and removed by an `EXIT` trap, so
a run never collides with — or cleans up — a real stack you have running.

## Known environment quirk

Docker Desktop on WSL writes `"credsStore": "desktop.exe"` into
`~/.docker/config.json`. `docker build` invokes that helper even for public
images and it is often not executable from inside the distro:

```
error getting credentials — fork/exec …/docker-credential-desktop.exe: exec format error
```

`docker run` and `docker pull` are unaffected, which makes it look
intermittent. `lib.sh` detects an unusable store and points `DOCKER_CONFIG` at
a scratch config for the run; it leaves a working store alone.
