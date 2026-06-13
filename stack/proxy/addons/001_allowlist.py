"""Domain allowlist for proxy egress control.

Reads /etc/agent-allowlist (bind-mounted from the host) to restrict which
external destinations the proxy will forward to. One domain per line; lines
starting with # and blank lines are ignored.

If the file is absent or unreadable, all destinations are permitted and a
warning is logged at startup. Restart the proxy after editing the file to
pick up changes.

Internal host blocking (broker, cred-gateway) is handled by policy.py, which
runs before this addon.
"""
import os
from typing import Optional, Set

from mitmproxy import ctx, http

_ALLOWLIST_PATH = "/etc/agent-allowlist"
_allowed: Optional[Set[str]] = None  # None means permissive (no file found)


def _load() -> Optional[Set[str]]:
    if not os.path.isfile(_ALLOWLIST_PATH):
        ctx.log.warn(
            f"allowlist: {_ALLOWLIST_PATH} not found or is not a file — "
            "all destinations permitted (permissive mode)"
        )
        return None
    entries: Set[str] = set()
    with open(_ALLOWLIST_PATH) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                entries.add(line.lower())
    ctx.log.info(f"allowlist: loaded {len(entries)} entries: {sorted(entries)}")
    return entries


def running() -> None:
    global _allowed
    _allowed = _load()


def request(flow: http.HTTPFlow) -> None:
    if _allowed is None:
        return
    host = flow.request.pretty_host.lower()
    if host not in _allowed:
        flow.response = http.Response.make(
            403,
            b'{"error":"destination blocked by allowlist policy"}',
            {"Content-Type": "application/json"},
        )
        ctx.log.warn(f"allowlist: BLOCKED {flow.request.method} {host}")