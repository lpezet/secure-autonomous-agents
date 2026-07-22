"""Block forwarding of requests to internal service hostnames.

The proxy sits on both the `secure` and `dev` networks, so it can reach
the broker. Without this addon, code inside the dev container could issue
plain HTTP proxy requests (e.g. curl --proxy http://proxy:8080 http://broker:8080/...)
and the proxy would happily forward them. This addon intercepts and rejects
any such request before it is forwarded.

Note: this matches by hostname, not IP. Docker network isolation is the
primary control that prevents dev from routing to broker's IP directly —
broker is on `secure` only, which dev has no membership in. This addon is
a defence-in-depth layer, not the sole barrier.
TODO: consider flipping to default-deny (allowlist of known-good external
hosts) as a hardening pass once the set of required destinations is known.
"""
from mitmproxy import http, ctx

_INTERNAL_HOSTS = {"broker", "cred-gateway"}


def _destination(flow: http.HTTPFlow) -> str:
    """Host this request will actually be sent to.

    NEVER use flow.request.pretty_host for a security decision. It prefers the
    client-supplied Host header, which the dev container fully controls, while
    mitmproxy connects to flow.request.host (from the absolute-form URI, the
    CONNECT authority, or the TLS SNI). Matching on pretty_host let

        curl --proxy http://proxy:8080 -H 'Host: example.com' \
             http://broker:8080/github/token

    sail past this addon and return a real installation token.
    """
    return flow.request.host


def request(flow: http.HTTPFlow) -> None:
    # Checked against both the real destination and the claimed one: the first
    # is the bypass above, the second stops a request being *labelled* internal
    # from reaching anything. Either match denies — fail closed.
    host = _destination(flow)
    if host in _INTERNAL_HOSTS or flow.request.pretty_host in _INTERNAL_HOSTS:
        flow.response = http.Response.make(
            403,
            b'{"error":"internal host blocked by proxy policy"}',
            {"Content-Type": "application/json"},
        )
        ctx.log.warn(
            f"policy: BLOCKED request to internal host {host} "
            f"(Host header: {flow.request.pretty_host})"
        )
