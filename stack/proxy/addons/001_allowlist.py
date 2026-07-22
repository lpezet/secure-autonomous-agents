"""Domain allowlist for proxy egress control.

Reads /etc/agent-allowlist (bind-mounted from the host) to restrict which
external destinations the proxy will forward to. One entry per line; lines
starting with # and blank lines are ignored.

Entry format:
  domain [METHODS]

  domain       Exact hostname or wildcard (*.example.com matches all subdomains).
  METHODS      Optional comma-separated HTTP methods to permit for this domain.
               Omitting METHODS defaults to GET,HEAD,OPTIONS (safe reads only).
               Use * to explicitly allow all methods.

Examples:
  api.example.com                   # GET, HEAD, OPTIONS only (default)
  api.example.com GET,POST          # GET and POST only
  upload.example.com PUT,POST       # write-only endpoint
  *.cdn.example.com *               # all methods for any subdomain

CONNECT is always permitted for allowlisted domains — it is the mechanism HTTPS
uses to establish the tunnel; the actual method is checked on the inner request.

If the file is absent or unreadable, all destinations are permitted and a
warning is logged at startup. After editing the file, restart the proxy to
pick up changes: docker compose up -d --force-recreate proxy

Internal host blocking (broker, cred-gateway) is handled by policy.py, which
runs before this addon.
"""
import os
from typing import Dict, List, Optional, Set, Tuple

from mitmproxy import ctx, http

_ALLOWLIST_PATH = "/etc/agent-allowlist"
_DEFAULT_METHODS = {"GET", "HEAD", "OPTIONS"}

# None means permissive mode (no file found).
# When active, maps domain → allowed methods (None = all methods).
_exact: Optional[Dict[str, Optional[Set[str]]]] = None
_wildcards: List[Tuple[str, Optional[Set[str]]]] = []  # (suffix, methods)


def _parse_methods(token: str) -> Optional[Set[str]]:
    """Return None for '*' (all methods), otherwise a set of uppercase method names."""
    if token == "*":
        return None
    return {m.strip().upper() for m in token.split(",") if m.strip()}


def _load() -> None:
    global _exact, _wildcards
    if not os.path.isfile(_ALLOWLIST_PATH):
        ctx.log.warn(
            f"allowlist: {_ALLOWLIST_PATH} not found or is not a file — "
            "all destinations permitted (permissive mode)"
        )
        _exact = None
        _wildcards = []
        return
    exact: Dict[str, Optional[Set[str]]] = {}
    wildcards: List[Tuple[str, Optional[Set[str]]]] = []
    with open(_ALLOWLIST_PATH) as fh:
        for line in fh:
            # Strip trailing comments before parsing. Without this,
            # `api.example.com  # read only` parses "# read only" as the method
            # list and silently blocks every method on that domain — fail-closed
            # but baffling to debug.
            line = line.split("#", 1)[0].strip() if not line.lstrip().startswith("#") else ""
            if not line:
                continue
            parts = line.lower().split(None, 1)
            domain = parts[0]
            methods = _parse_methods(parts[1]) if len(parts) > 1 else set(_DEFAULT_METHODS)
            if domain.startswith("*."):
                wildcards.append((domain[1:], methods))  # store as ".example.com"
            else:
                exact[domain] = methods
    ctx.log.info(
        f"allowlist: loaded {len(exact)} exact + {len(wildcards)} wildcard entries"
    )
    _exact = exact
    _wildcards = wildcards


def _is_allowed(host: str, method: str) -> bool:
    # CONNECT establishes the HTTPS tunnel; the real method is on the inner request.
    if method == "CONNECT":
        if host in _exact:
            return True
        return any(host.endswith(w) for w, _ in _wildcards)

    methods: Optional[Set[str]] = None  # sentinel: not found
    found = False
    if host in _exact:
        methods = _exact[host]
        found = True
    else:
        for suffix, m in _wildcards:
            if host.endswith(suffix):
                methods = m
                found = True
                break
    if not found:
        return False
    return methods is None or method.upper() in methods


def running() -> None:
    _load()


def request(flow: http.HTTPFlow) -> None:
    if _exact is None:
        return
    # flow.request.host is the real destination. Do NOT use pretty_host here:
    # it prefers the client-supplied Host header, so the dev container could
    # point a request at its own server, spoof the header, and have the real
    # credential injected into a request that never goes to the vendor.
    host = flow.request.host.lower()
    method = flow.request.method
    if not _is_allowed(host, method):
        flow.response = http.Response.make(
            403,
            b'{"error":"destination blocked by allowlist policy"}',
            {"Content-Type": "application/json"},
        )
        ctx.log.warn(f"allowlist: BLOCKED {method} {host}")