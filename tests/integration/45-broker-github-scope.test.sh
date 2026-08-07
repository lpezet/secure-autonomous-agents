#!/usr/bin/env bash
# The audit trail says what an issued GitHub token can do, not just that one
# was issued.
#
# The broker mints installation tokens at whatever scope the App's installation
# grants, and that grant is set in GitHub's web UI — outside this stack. So the
# stack inherits a ceiling it never chose. Recording only "token_issued" means
# "what can this lab currently do to GitHub?" is answered by opening GitHub
# settings rather than by reading the trail.
#
# Testing this needs the real github.js, which talks to api.github.com over
# HTTPS with a signed App JWT. Rather than stub the provider (which would test
# nothing), this stands up a TLS stub *as* api.github.com:
#
#   - a throwaway RSA key, generated here, so octokit can sign a real App JWT
#   - --add-host api.github.com:<stub> so the broker's own DNS points at it
#   - NODE_TLS_REJECT_UNAUTHORIZED=0 so the self-signed cert is accepted
#
# Nothing here is a credential: the key is generated per run and never leaves
# the container, and the tokens the stub hands back are obvious fakes.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-broker"
build_image "$IMG" stack/broker || exit 1

# Obvious fakes. FAKE_TOKEN must not look like a real credential shape or
# 00-config-lint's repo-wide sweep would flag this file.
FAKE_TOKEN="STUB-INSTALLATION-TOKEN-VALUE"
APP_ID=1
INSTALL_ID=42

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; cleanup' EXIT

# App private key. Generated per run; octokit signs the JWT with it and the stub
# never verifies the signature, but auth-app refuses to run without a real one.
openssl genrsa -out "$WORK/app.pem" 2048 >/dev/null 2>&1
# Self-signed leaf for the stub. CN is irrelevant — verification is off.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=api.github.com" -keyout "$WORK/stub.key" -out "$WORK/stub.crt" \
  >/dev/null 2>&1

EXPIRES=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)

# The two endpoints github.js needs, and only those.
#
# access_tokens carries `permissions` — that is the half that comes free on the
# installation auth object. The installation endpoint carries
# `repository_selection`, which does NOT appear on that object unless narrowing
# options were passed in, and is the reason for the second call.
cat > "$WORK/stub.conf" <<EOF
server {
  listen 443 ssl;
  ssl_certificate     /certs/stub.crt;
  ssl_certificate_key /certs/stub.key;
  default_type application/json;

  location = /app/installations/$INSTALL_ID/access_tokens {
    return 201 '{"token":"$FAKE_TOKEN","expires_at":"$EXPIRES","permissions":{"contents":"write","pull_requests":"write"},"repository_selection":"selected"}';
  }
  location = /app/installations/$INSTALL_ID {
    return 200 '{"id":$INSTALL_ID,"repository_selection":"selected","permissions":{"contents":"write","pull_requests":"write"}}';
  }
  location / { return 404 '{"message":"stub: no such endpoint"}'; }
}
EOF

# Same stub with the installation endpoint absent, for the degradation case.
# A second container rather than an edit-and-reload: `sed -i` writes a new
# inode, which a bind mount does not follow, so the container would keep
# serving the original file and the suite would pass for the wrong reason.
sed 's|location = /app/installations/'"$INSTALL_ID"' {|location = /app/installations/'"$INSTALL_ID"'/gone {|' \
  "$WORK/stub.conf" > "$WORK/stub-degraded.conf"

net_up
curl_up

GH="$RUN_ID-ghstub"
docker run -d --name "$GH" --network "$NET" \
  -v "$WORK/stub.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$WORK/stub.crt:/certs/stub.crt:ro" \
  -v "$WORK/stub.key:/certs/stub.key:ro" nginx:alpine >/dev/null
track_container "$GH"

STUB_IP=$(docker inspect -f \
  '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$GH")

BK="$RUN_ID-broker-gh"
docker run -d --name "$BK" --network "$NET" \
  --add-host "api.github.com:$STUB_IP" \
  -v "$REPO_ROOT/bank/github/broker:/app/providers:ro" \
  -v "$WORK/app.pem:/secrets/github-app.pem:ro" \
  -e GITHUB_APP_ID="$APP_ID" \
  -e GITHUB_APP_INSTALLATION_ID="$INSTALL_ID" \
  -e GITHUB_APP_PRIVATE_KEY_PATH=/secrets/github-app.pem \
  -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
  -e AUDIT_LOG=/tmp/audit.jsonl "$IMG" >/dev/null
track_container "$BK"

if ! wait_http "$BK:8080/healthz" 200 "broker"; then
  ko "broker did not start" "$(docker logs "$BK" 2>&1 | tail -20)"
  finish
fi

# ------------------------------------------------------------- the trail exists
#
# Guards against a vacuous pass: every absence asserted below is also what an
# empty trail looks like, so prove the trail is live first.
suite "the token route works against the stub"
body=$(http_body "http://$BK:8080/github/token")
check_contains "a token is issued" "$body" "$FAKE_TOKEN"

trail=$(docker exec "$BK" cat /tmp/audit.jsonl 2>/dev/null)
check_contains "and the trail is live" "$trail" '"event":"token_issued"'

# ------------------------------------------------------------------ the scope
suite "the trail names what the token can do"
check_contains "permissions are recorded" "$trail" '"permissions"'
check_contains "each granted permission by name" "$trail" '"contents":"write"'
check_contains "including the second one" "$trail" '"pull_requests":"write"'
check_contains "and whether the installation is org-wide" \
  "$trail" '"repository_selection":"selected"'

suite "the credential route reports the same scope"
# git push travels this one. Leaving it out would make the most-used path the
# least visible.
body=$(http_body "http://$BK:8080/github/credential")
check_contains "a credential is issued" "$body" "x-access-token"
trail=$(docker exec "$BK" cat /tmp/audit.jsonl 2>/dev/null)
check_contains "credential_issued carries permissions too" "$trail" '"event":"credential_issued"'
line=$(printf '%s\n' "$trail" | grep credential_issued | tail -1)
check_contains "with the same fields" "$line" '"repository_selection":"selected"'

# ------------------------------------------------------------------ the limits
suite "no credential value reaches the trail"
# The one thing this feature must not get wrong. Scope is metadata about a
# token; the token is not.
trail=$(docker exec "$BK" cat /tmp/audit.jsonl 2>/dev/null)
check_not_contains "the issued token is absent" "$trail" "$FAKE_TOKEN"
check_not_contains "no private key material" "$trail" "PRIVATE KEY"

suite "repository names are deliberately not logged"
# observer serves this trail over HTTP. repository_selection answers the
# question the ceiling is about; enumerating private repo names would be signal
# for no benefit. If a later change starts logging them, this is the assertion
# that should have to be argued with.
check_not_contains "no repositories array" "$trail" '"repositories"'

suite "an unavailable installation lookup degrades the trail, not the token"
# Describing a token must never be what stops it being issued. Minting still
# works against a stub with no installation endpoint; the scope field says so
# rather than guessing, and rather than the route failing.
GH2="$RUN_ID-ghstub-degraded"
docker run -d --name "$GH2" --network "$NET" \
  -v "$WORK/stub-degraded.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$WORK/stub.crt:/certs/stub.crt:ro" \
  -v "$WORK/stub.key:/certs/stub.key:ro" nginx:alpine >/dev/null
track_container "$GH2"

STUB2_IP=$(docker inspect -f \
  '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$GH2")

BK2="$RUN_ID-broker-gh-degraded"
docker run -d --name "$BK2" --network "$NET" \
  --add-host "api.github.com:$STUB2_IP" \
  -v "$REPO_ROOT/bank/github/broker:/app/providers:ro" \
  -v "$WORK/app.pem:/secrets/github-app.pem:ro" \
  -e GITHUB_APP_ID="$APP_ID" \
  -e GITHUB_APP_INSTALLATION_ID="$INSTALL_ID" \
  -e GITHUB_APP_PRIVATE_KEY_PATH=/secrets/github-app.pem \
  -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
  -e AUDIT_LOG=/tmp/audit.jsonl "$IMG" >/dev/null
track_container "$BK2"

if wait_http "$BK2:8080/healthz" 200 "degraded broker"; then
  body=$(http_body "http://$BK2:8080/github/token")
  check_contains "the token is still issued" "$body" "$FAKE_TOKEN"
  trail2=$(docker exec "$BK2" cat /tmp/audit.jsonl 2>/dev/null)
  check_contains "permissions still recorded" "$trail2" '"contents":"write"'
  check_contains "and the missing half says so" "$trail2" '"repository_selection":"unknown"'
else
  ko "degraded broker did not start" "$(docker logs "$BK2" 2>&1 | tail -20)"
fi

finish
