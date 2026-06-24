"""Inject Anthropic credentials (API key or OAuth token), enforce policy, log usage."""
import requests
from mitmproxy import http, ctx
from cachetools import TTLCache

_cache = TTLCache(maxsize=1, ttl=300)
BROKER_URL = "http://broker:8080"


def _get_cred():
    """Return (type, value) from broker, cached for 5 minutes."""
    if "cred" not in _cache:
        r = requests.get(f"{BROKER_URL}/anthropic/cred", timeout=5)
        r.raise_for_status()
        data = r.json()
        _cache["cred"] = (data["type"], data["value"])
    return _cache["cred"]


def request(flow: http.HTTPFlow) -> None:
    if flow.request.pretty_host != "api.anthropic.com":
        return

    # Policy: block Admin API from agent context
    if flow.request.path.startswith("/v1/organizations"):
        flow.response = http.Response.make(
            403,
            b'{"error":"Admin API blocked by proxy policy"}',
            {"Content-Type": "application/json"},
        )
        ctx.log.warn(f"anthropic: BLOCKED {flow.request.method} {flow.request.path}")
        return

    cred_type, cred_value = _get_cred()

    # Strip whichever auth headers the agent sent, then inject the real credential.
    for h in ("x-api-key", "Authorization"):
        if h in flow.request.headers:
            del flow.request.headers[h]

    if cred_type == "auth_token":
        flow.request.headers["Authorization"] = f"Bearer {cred_value}"
        ctx.log.info(f"anthropic: injected auth token for {flow.request.method} {flow.request.path}")
    else:
        flow.request.headers["x-api-key"] = cred_value
        flow.request.headers["anthropic-version"] = flow.request.headers.get(
            "anthropic-version", "2023-06-01"
        )
        ctx.log.info(f"anthropic: injected api key for {flow.request.method} {flow.request.path}")


def responseheaders(flow: http.HTTPFlow) -> None:
    """Use responseheaders, not response, to avoid buffering streamed bodies."""
    if flow.request.pretty_host != "api.anthropic.com":
        return
    if "text/event-stream" in flow.response.headers.get("Content-Type", ""):
        flow.response.stream = True

    remaining = flow.response.headers.get("anthropic-ratelimit-tokens-remaining")
    if remaining:
        ctx.log.info(f"anthropic: tokens remaining = {remaining}")
