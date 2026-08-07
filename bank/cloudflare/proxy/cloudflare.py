"""Inject Cloudflare scoped token for api.cloudflare.com calls."""
import os

import requests
from mitmproxy import http, ctx
from cachetools import TTLCache

import audit

_cache = TTLCache(maxsize=4, ttl=300)
BROKER_URL = "http://broker:8080"

# Which profile this deployment issues. Read once at load from the proxy's own
# environment: deployment configuration, never request data. See request().
PROFILE = os.environ.get("CLOUDFLARE_PROFILE", "workers-deploy")


def _get_token(profile: str) -> str:
    if profile not in _cache:
        r = requests.get(
            f"{BROKER_URL}/cloudflare/token", params={"profile": profile}, timeout=5
        )
        r.raise_for_status()
        _cache[profile] = r.json()["token"]
    return _cache[profile]


def _endpoint(flow: http.HTTPFlow) -> str:
    """A loggable identifier for what was called, never the raw path.

    flow.request.path includes the query string, and Cloudflare paths carry
    account and zone ids (/client/v4/zones/<zone_id>/...). Keeping the first
    three segments names the API surface without writing ids — or, in an addon
    adapted for a provider that puts its credential in the URL, a live secret —
    into a trail that observer serves over HTTP. See 020_anthropic.py for the
    longer note on choosing a safe slice.
    """
    parts = [p for p in flow.request.path.split("?", 1)[0].split("/") if p][:3]
    return "/" + "/".join(parts)


def request(flow: http.HTTPFlow) -> None:
    # flow.request.host is the real destination. Do NOT use pretty_host here:
    # it prefers the client-supplied Host header, so the lab container could
    # point a request at its own server, spoof the header, and have the real
    # credential injected into a request that never goes to the vendor.
    if flow.request.host != "api.cloudflare.com":
        return

    # X-Cf-Profile is dropped, not read. It used to select the profile, which
    # made the lab container the author of its own authority: a ladder of
    # profiles (dev / qa / prod-read / prod-ir) is decorative if the agent picks
    # its own rung, and every audit line would faithfully record that `prod-ir`
    # was issued to a caller entitled to `dev`. Same rule as flow.request.host
    # over pretty_host above — a security decision must not be made from a value
    # the untrusted side controls. Still stripped so it never reaches the vendor.
    flow.request.headers.pop("X-Cf-Profile", None)

    # Strip first, as its own statement. _get_token() raises when the broker is
    # unreachable, so a single assignment that both strips and injects strips
    # nothing on failure and forwards the agent's own Authorization header to
    # Cloudflare untouched — the opposite of what the strip is for.
    if "Authorization" in flow.request.headers:
        del flow.request.headers["Authorization"]

    flow.request.headers["Authorization"] = f"Bearer {_get_token(PROFILE)}"
    ctx.log.info(
        f"cloudflare: {flow.request.method} {_endpoint(flow)} (profile={PROFILE})"
    )
    audit.log_event(
        "token_injected", provider="cloudflare", profile=PROFILE,
        method=flow.request.method, endpoint=_endpoint(flow),
    )
