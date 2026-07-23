"""Inject Cloudflare scoped token for api.cloudflare.com calls."""
import requests
from mitmproxy import http, ctx
from cachetools import TTLCache

_cache = TTLCache(maxsize=4, ttl=300)
BROKER_URL = "http://broker:8080"
DEFAULT_PROFILE = "workers-deploy"


def _get_token(profile: str) -> str:
    if profile not in _cache:
        r = requests.get(
            f"{BROKER_URL}/cloudflare/token", params={"profile": profile}, timeout=5
        )
        r.raise_for_status()
        _cache[profile] = r.json()["token"]
    return _cache[profile]


def request(flow: http.HTTPFlow) -> None:
    # flow.request.host is the real destination. Do NOT use pretty_host here:
    # it prefers the client-supplied Host header, so the dev container could
    # point a request at its own server, spoof the header, and have the real
    # credential injected into a request that never goes to the vendor.
    if flow.request.host != "api.cloudflare.com":
        return

    # Allow caller to hint a profile via custom header (stripped before forwarding)
    profile = flow.request.headers.pop("X-Cf-Profile", DEFAULT_PROFILE)
    flow.request.headers["Authorization"] = f"Bearer {_get_token(profile)}"
    ctx.log.info(
        f"cloudflare: {flow.request.method} {flow.request.path} (profile={profile})"
    )
