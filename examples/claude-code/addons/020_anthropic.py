"""Inject Anthropic API key, enforce policy, log usage."""
import requests
from mitmproxy import http, ctx
from cachetools import TTLCache

_cache = TTLCache(maxsize=1, ttl=300)
BROKER_URL = "http://broker:8080"


def _get_key():
    if "key" not in _cache:
        r = requests.get(f"{BROKER_URL}/anthropic/key", timeout=5)
        r.raise_for_status()
        _cache["key"] = r.json()["key"]
    return _cache["key"]


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

    flow.request.headers["x-api-key"] = _get_key()
    flow.request.headers["anthropic-version"] = flow.request.headers.get(
        "anthropic-version", "2023-06-01"
    )
    if "Authorization" in flow.request.headers:
        del flow.request.headers["Authorization"]

    ctx.log.info(f"anthropic: {flow.request.method} {flow.request.path}")


def responseheaders(flow: http.HTTPFlow) -> None:
    """Use responseheaders, not response, to avoid buffering streamed bodies."""
    if flow.request.pretty_host != "api.anthropic.com":
        return
    if "text/event-stream" in flow.response.headers.get("Content-Type", ""):
        flow.response.stream = True

    remaining = flow.response.headers.get("anthropic-ratelimit-tokens-remaining")
    if remaining:
        ctx.log.info(f"anthropic: tokens remaining = {remaining}")
