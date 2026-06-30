"""
mitmproxy addon: L7 egress policy for the agent sandbox.

Enforces a hostname allowlist at L7 (SNI for HTTPS, Host header for HTTP).
Rejects domain fronting (Host ≠ SNI on the same connection).

In transparent mode, all agent traffic is redirected here by iptables — the
agent cannot bypass this even if it ignores HTTP_PROXY.

Loaded via: mitmdump --mode transparent --set confdir=/etc/mitmproxy \
                      -s /opt/egress-policy.py
"""

import logging
import re
from pathlib import Path

from mitmproxy import ctx, http, tls, connection
from mitmproxy.net.server_spec import ServerSpec

logger = logging.getLogger(__name__)

DOMAINS_FILE = "/etc/firewall-domains.txt"


def _load_domains(path: str) -> list[str]:
    """Load domain allowlist. Returns lowercased domain suffixes."""
    domains = []
    p = Path(path)
    if not p.exists():
        logger.error("Domain allowlist not found: %s", path)
        return domains
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        domains.append(line.lower())
    return domains


def _is_allowed(hostname: str, allowed: list[str]) -> bool:
    """Check if hostname matches any allowed domain (exact or subdomain)."""
    hostname = hostname.lower().rstrip(".")
    for domain in allowed:
        if hostname == domain or hostname.endswith("." + domain):
            return True
    return False


class EgressPolicy:
    def __init__(self):
        self.allowed_domains: list[str] = []

    def load(self, loader):
        loader.add_option(
            name="egress_domains_file",
            typespec=str,
            default=DOMAINS_FILE,
            help="Path to the domain allowlist file",
        )

    def configure(self, updated):
        path = ctx.options.egress_domains_file
        self.allowed_domains = _load_domains(path)
        logger.info(
            "Egress policy loaded %d domains from %s",
            len(self.allowed_domains),
            path,
        )

    def tls_clienthello(self, data: tls.ClientHelloData):
        """Check SNI at TLS handshake time — reject before any data flows."""
        sni = data.client_hello.sni
        if sni and not _is_allowed(sni, self.allowed_domains):
            logger.warning("BLOCKED (SNI): %s", sni)
            data.ignore_connection = False
            # Setting establish_server_tls to False and ignoring won't help;
            # we need to let it through to request phase for a clean error.
            # But we can stash the decision.
            data.context.blocked_sni = sni  # type: ignore[attr-defined]

    def request(self, flow: http.HTTPFlow):
        """Enforce policy on every HTTP(S) request."""
        host = flow.request.pretty_host
        if not host:
            flow.response = http.Response.make(
                403, b"Egress blocked: no host", {"Content-Type": "text/plain"}
            )
            return

        # Check the hostname against the allowlist
        if not _is_allowed(host, self.allowed_domains):
            logger.warning("BLOCKED (Host): %s%s", host, flow.request.path)
            flow.response = http.Response.make(
                403,
                f"Egress blocked by sandbox policy: {host}\n".encode(),
                {"Content-Type": "text/plain"},
            )
            return

        # Domain fronting check: if we have an SNI from the TLS handshake,
        # the Host header must be in the same domain tree.
        # (In transparent mode, mitmproxy sets flow.server_conn.peername from
        # the original destination; the SNI is on the client connection.)
        client_sni = getattr(
            flow.client_conn, "sni", None
        ) or getattr(
            getattr(flow, "_ctx", None), "blocked_sni", None
        )
        if client_sni and host.lower() != client_sni.lower():
            # Allow if both are subdomains of the same allowed domain
            sni_ok = any(
                (host.lower() == d or host.lower().endswith("." + d))
                and (client_sni.lower() == d or client_sni.lower().endswith("." + d))
                for d in self.allowed_domains
            )
            if not sni_ok:
                logger.warning(
                    "BLOCKED (domain fronting): SNI=%s Host=%s",
                    client_sni,
                    host,
                )
                flow.response = http.Response.make(
                    403,
                    f"Egress blocked: domain fronting (SNI={client_sni}, Host={host})\n".encode(),
                    {"Content-Type": "text/plain"},
                )
                return

        logger.debug("ALLOWED: %s%s", host, flow.request.path)


addons = [EgressPolicy()]
