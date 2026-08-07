#!/usr/bin/env bash
# invariants.sh — static checks that a single file is safe on its own terms.
#
# Sourced by two callers that ask different questions:
#
#   tests/integration/00-config-lint.test.sh   is OUR code safe?
#   scripts/check-invariants.sh                is YOUR code safe?
#
# One copy on purpose. These patterns encode incidents — a leaked query string,
# a spoofed Host, a fail-open strip — and two copies of them would drift, which
# is the failure this repo documents everywhere else.
#
# Contract for every inv_* function:
#   inv_<name> <file>   → prints "LINE: evidence" per finding on stdout
#                         returns 0 when clean, 1 when it found something
#
# Dependency-free: bash, grep, sed, awk. No git, no jq, no network — a
# deployment must be able to run this against its own files with nothing
# installed and no checkout of this repo.
#
# These are greps. They check a known list and cannot prove a file is safe.
# Callers must never render a clean result as "pass" — see check-invariants.sh.

# ---------------------------------------------------------------- shared data

# Broker routes that must never be exposed through a cred-gateway snippet:
# each hands over a reusable secret rather than spending it on the lab's behalf.
#
# Static on purpose. The scanner runs on a deployment with no checkout, so it
# cannot derive this from bank/*/provider.json the way the lint does. Instead
# 00-config-lint asserts this list is a SUPERSET of every "exposed": false route
# in the bank — so adding a provider whose unexposed route is missing here fails
# upstream CI rather than silently narrowing what a deployment gets checked for.
INV_DENY_PATHS="/github/token /anthropic/cred /anthropic/key /cloudflare/token"

# Env vars that must hold the inert placeholder, never a real credential.
INV_PLACEHOLDER_VARS="GH_TOKEN CLOUDFLARE_API_TOKEN ANTHROPIC_API_KEY"
INV_PLACEHOLDER_VALUE="proxy-injected"

# Credential shapes. Length-bounded so `.env.example` stubs (sk-ant-…, ghp_xxx)
# do not trip while a real key still would.
INV_CRED_PATTERNS='sk-ant-[A-Za-z0-9_-]{20,}
ghp_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
BEGIN RSA PRIVATE KEY
BEGIN PRIVATE KEY
BEGIN OPENSSH PRIVATE KEY'

# ------------------------------------------------------------------- helpers

# Two characters these checks must match literally, held as constants rather
# than escaped inline. `'\''` gymnastics inside a "$( … )" is how this file
# first failed to parse at all, and a security check that does not load is
# worse than one that is slightly ugly.
_INV_SQ=$(printf '\047')   # '
_INV_BT=$(printf '\140')   # `

# _inv_strip_py <file> — python source with comments and docstrings removed.
# Every shipped addon explains these anti-patterns in its own prose; without
# this, each one reports itself.
_inv_strip_py() {
  awk '
    { line = $0; sub(/#.*$/, "", line) }
    # Same-line docstrings close as fast as they open, so the block counter
    # below never sees them. Drop them first.
    { gsub(/"""[^"]*"""/, "", line); gsub(/\x27\x27\x27[^\x27]*\x27\x27\x27/, "", line) }
    { q = gsub(/"""/, "&", line) + gsub(/\x27\x27\x27/, "&", line) }
    ds  { if (q % 2 == 1) ds = 0; print ""; next }
    q % 2 == 1 { ds = 1; print ""; next }
    { print line }
  ' "$1"
}

# _inv_report <file> <grep-output> — pass grep -n output through unchanged,
# returning 1 when there was any. Keeps every check's tail identical.
_inv_report() {
  [ -z "$2" ] && return 0
  printf '%s\n' "$2"
  return 1
}

# ------------------------------------------------------- checks: proxy addons

# The trail is a plaintext file observer serves over HTTP, and
# flow.request.path includes the query string. For a provider carrying its
# credential in the URL, `path=flow.request.path` writes a live secret into it.
inv_raw_path_logged() {
  _inv_report "$1" "$(grep -n 'path=flow\.request\.path' "$1" 2>/dev/null | grep -v "$_INV_BT")"
}

# The same bug wearing a parse. Because the raw path carries the query string,
# the last segment absorbs it: on /bot<TOKEN>/sendMessage?chat_id=…&text=…,
# split("/")[2] is the message body, not the method. The token sits in segment
# 1 and stays out, which is exactly what let the mistake read as safe.
inv_raw_path_split() {
  _inv_report "$1" "$(grep -n 'flow\.request\.path\.split("/")' "$1" 2>/dev/null | grep -v "$_INV_BT")"
}

# pretty_host prefers the client-supplied Host header, so matching on it lets
# `curl -H 'Host: api.anthropic.com' http://my-server/` collect a real injected
# credential. First non-obvious invariant in CLAUDE.md, with a real regression
# behind it.
#
# 000_policy.py is the one legitimate use — it ORs pretty_host with the real
# host to *widen* a block, and trusting a claimed Host to deny more is safe.
# Callers skip that file by name rather than trying to tell the two apart here.
inv_pretty_host() {
  _inv_report "$1" "$(_inv_strip_py "$1" | grep -n 'pretty_host')"
}

# An exception message is free text from whoever raised it, and providers
# interpolate vendor responses into theirs. Only .code and .name are safe to
# put in an audit event; detail belongs on stdout, which observer does not read.
#
# Allowlist, not blocklist: enumerating the ways of writing "the error" loses to
# the next one invented. Strip the field names, strip the two permitted
# references, flag whatever still names the exception.
inv_exception_quoted() {
  _inv_report "$1" "$(awk '
    { line = $0; sub(/[[:space:]]*(\/\/|#).*$/, "", line) }
    !inside && line ~ /log_?[Ee]vent\(/ { inside = 1; start = NR; buf = ""; depth = 0 }
    inside {
      buf = buf " " line
      n = gsub(/\(/, "(", line); depth += n
      n = gsub(/\)/, ")", line); depth -= n
      if (depth > 0) next
      inside = 0
      t = buf
      # Brace-free quoted literals are values, not references. An f-string is a
      # reference wearing a literal, so those stay visible; so do backticks.
      gsub(/"[^"{}]*"/, "", t); gsub(/\x27[^\x27{}]*\x27/, "", t)
      gsub(/(err|error|e|ex|exc)[[:space:]]*[:=]/, "", t)
      gsub(/(err|error|e|ex|exc)\.(code|name)/, "", t)
      if (t ~ /(^|[^[:alnum:]_.])(err|error|e|ex|exc)([^[:alnum:]_]|$)/) print start ": " buf
    }' "$1" 2>/dev/null)"
}

# A request header is written by the lab container. An addon that reads one
# into a variable is letting the untrusted side steer what happens next — and in
# a credential-injecting addon, what happens next is which credential gets
# attached. 030_cloudflare.py shipped exactly this: `X-Cf-Profile` chose the
# profile, so a ladder of dev/qa/prod profiles was decorative, and the audit
# line recorded the escalated profile as though it had been authorised.
#
# Stripping is not reading. A bare `flow.request.headers.pop("X-Foo", None)` or
# `del flow.request.headers["Authorization"]` is the correct way to drop a
# client header and does not match; binding the value to a name does.
#
# Same family as inv_pretty_host: both catch a decision made from client-
# supplied data. This one is the general case, that one the specific host bug.
inv_header_selector() {
  _inv_report "$1" "$(_inv_strip_py "$1" \
    | grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*flow\.request\.headers\.(get|pop)\(')"
}

# git push/pull to github.com authenticates through the credential helper, not
# header injection. Matching it here collides with git's own Basic-auth
# handshake inside the MITM'd tunnel.
inv_github_com_matched() {
  _inv_report "$1" "$(_inv_strip_py "$1" | grep -nE "\"github\\.com\"|${_INV_SQ}github\\.com${_INV_SQ}")"
}

# --------------------------------------------------- checks: gateway snippets

# `location /github/` exposes every broker route under it, including
# /github/token. Exact match only.
inv_location_prefix() {
  _inv_report "$1" "$(grep -nE '^[[:space:]]*location[[:space:]]+[^=]' "$1" 2>/dev/null)"
}

# Exposing one of these hands the lab a reusable secret instead of spending it
# on the lab's behalf. They belong in a proxy addon.
inv_raw_cred_endpoint() {
  local f="$1" p out=""
  for p in $INV_DENY_PATHS; do
    out="$out$(grep -nE "location[[:space:]]*=[[:space:]]*$p([[:space:]]|\{|$)" "$f" 2>/dev/null)"$'\n'
  done
  out=$(printf '%s' "$out" | grep -v '^$' || true)
  _inv_report "$f" "$out"
}

# ---------------------------------------------------------- checks: compose

# These are dummy values satisfying a client's "am I authenticated?" check; the
# proxy strips and replaces them at the wire. A real one here is a credential
# sitting in the untrusted container.
inv_real_credential() {
  local f="$1" var line num rest val out=""
  for var in $INV_PLACEHOLDER_VARS; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # grep -n prefixes "NNN:", and the YAML pair adds its own colon, so the
      # value is what follows the *second* one.
      num=${line%%:*}; rest=${line#*:}
      val=$(printf '%s' "${rest#*:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d "\"$_INV_SQ")
      case "$val" in
        # An unresolved ${VAR} interpolation is the deployment's business, not
        # a literal credential — flagging it would punish the safe pattern.
        "$INV_PLACEHOLDER_VALUE"|'${'*|'') ;;
        *) out="$out$num: $var is '$val', not '$INV_PLACEHOLDER_VALUE'"$'\n' ;;
      esac
    done <<EOF
$(grep -nE "^[[:space:]]*$var:" "$f" 2>/dev/null)
EOF
  done
  out=$(printf '%s' "$out" | grep -v '^$' || true)
  _inv_report "$f" "$out"
}

# observer publishes the audit trail over HTTP with no auth. Binding its port to
# all interfaces puts the trail on the network.
inv_observer_port() {
  _inv_report "$1" "$(grep -nE '^[[:space:]]*-[[:space:]]*"?[0-9]+:9000"?' "$1" 2>/dev/null)"
}

# ---------------------------------------------------------- checks: providers

# A credential read from an env VALUE is visible in `docker inspect` and
# /proc/<pid>/environ. The convention is a *_PATH var naming a file under the
# read-only /secrets mount.
inv_env_value_credential() {
  _inv_report "$1" "$(grep -nE 'process\.env\.[A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)([^A-Za-z0-9_]|$)' "$1" 2>/dev/null \
    | grep -v '_PATH' | grep -v "$_INV_BT")"
}

# The lab network must have no default gateway. Without that, HTTP_PROXY is a
# request the agent can decline — `curl --noproxy '*'` leaves the box without
# touching the proxy, so the egress allowlist governs cooperating traffic only.
#
# Reports the *absence* of the control, so it fires on a compose file that never
# had the key as well as on one that opted out. A deployment predating this is
# the common case and is exactly what should be told.
inv_egress_unmediated() {
  local f="$1" block line
  # Only the lab network. `secure` is deliberately not internal: broker calls
  # provider APIs directly through it.
  #
  # Scoped to the top-level `networks:` section. A service is commonly named
  # `lab` too, and an earlier cut of this matched that block instead — it only
  # looked correct because the real network block further down supplied the
  # key it was looking for.
  block=$(awk '
    /^networks:[[:space:]]*$/ { innet = 1; next }
    /^[^[:space:]#]/          { innet = 0 }
    innet && /^[[:space:]]+lab:[[:space:]]*$/ { inlab = 1; print NR ": " $0; next }
    innet && inlab && /^[[:space:]]{1,2}[a-zA-Z_-]+:/ { inlab = 0 }
    innet && inlab { print NR ": " $0 }
  ' "$f" 2>/dev/null)
  [ -n "$block" ] || return 0            # no lab network declared here at all

  line=$(printf '%s\n' "$block" | grep 'internal:' || true)
  if [ -z "$line" ]; then
    printf '%s: lab network has no `internal:` key — egress is unmediated\n' \
      "$(printf '%s' "$block" | head -1 | cut -d: -f1)"
    return 1
  fi
  # An unresolved ${LAB_INTERNAL:-true} is the shipped default and is fine.
  case "$line" in
    *'internal: false'*|*'internal: "false"'*|*':-false}'*)
      printf '%s\n' "${line%%:*}: lab network is not internal — egress is unmediated"
      return 1 ;;
  esac
  return 0
}

# --------------------------------------------------------------- checks: any

# A credential-shaped literal anywhere in a deployment file. The lint sweeps the
# whole repo with git grep; here the same patterns run per file, so a secret
# pasted into an addon or a compose file is caught even though nothing tracks it.
inv_credential_material() {
  local f="$1" pat out=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    out="$out$(grep -nE "$pat" "$f" 2>/dev/null | cut -c1-120)"$'\n'
  done <<EOF
$INV_CRED_PATTERNS
EOF
  out=$(printf '%s' "$out" | grep -v '^$' || true)
  _inv_report "$f" "$out"
}

# ------------------------------------------------------- directory-level check

# 000_policy.py must run before any addon can act on a request; entrypoint.sh
# globs alphabetically. Not per-file, so it takes a directory.
inv_policy_addon_first() {
  local d="$1" first
  first=$(ls "$d"/*.py 2>/dev/null | head -1)
  [ -n "$first" ] || return 0
  first=$(basename "$first")
  [ "$first" = "000_policy.py" ] && return 0
  printf '0: first addon is %s, not 000_policy.py\n' "$first"
  return 1
}

# -------------------------------------------------------------- the registry
#
# Both callers dispatch from here, so neither can quietly check a different set.
# Fields: name|severity|applies-to|one-line description

INV_REGISTRY='raw_path_logged|fail|proxy_py|logs a raw request path, query string included
raw_path_split|fail|proxy_py|splits a raw path on "/", so the last segment holds the query string
pretty_host|fail|proxy_py|decides on the client-supplied Host header
header_selector|fail|proxy_py|binds a client-supplied request header to a name the addon acts on
github_com_matched|fail|proxy_py|matches github.com, which the credential helper owns
exception_quoted|fail|proxy_py broker_js|audit event quotes an exception beyond .code/.name
location_prefix|fail|gateway_conf|prefix-match location exposes every route beneath it
raw_cred_endpoint|fail|gateway_conf|exposes a raw-credential broker route to the lab
real_credential|fail|compose|env var holds something other than the inert placeholder
env_value_credential|note|broker_js|credential read from an env value rather than a *_PATH file
observer_port|note|compose|observer port is not bound to loopback
credential_material|fail|proxy_py broker_js gateway_conf compose|credential-shaped string in a deployment file
egress_unmediated|fail|compose|lab network is not internal, so the proxy can be bypassed'

# inv_field <name> <1=severity|2=applies|3=description>
inv_field() {
  printf '%s\n' "$INV_REGISTRY" | awk -F'|' -v n="$1" -v i="$2" '$1 == n { print $(i+1); exit }'
}

# inv_checks_for <kind> — check names applying to a file kind, in registry order.
inv_checks_for() {
  printf '%s\n' "$INV_REGISTRY" | awk -F'|' -v k="$1" '
    { split($3, a, " "); for (i in a) if (a[i] == k) { print $1; break } }'
}

# inv_kind <path> — classify by directory and extension, the way a deployment
# is laid out. Prints nothing for a file we have no checks for.
inv_kind() {
  local f="$1" b d
  b=$(basename "$f"); d=$(basename "$(dirname "$f")")
  case "$b" in
    compose.yaml|compose.yml|docker-compose.yaml|docker-compose.yml) printf 'compose'; return ;;
  esac
  case "$d/$b" in
    proxy/*.py)         printf 'proxy_py' ;;
    broker/*.js)        printf 'broker_js' ;;
    cred-gateway/*.conf) printf 'gateway_conf' ;;
  esac
}
