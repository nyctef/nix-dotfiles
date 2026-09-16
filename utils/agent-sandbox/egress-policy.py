"""
mitmproxy addon: L7 egress policy for the agent sandbox.

Enforces a hostname allowlist at L7. The proxy runs in regular (explicit)
mode, so the destination the agent actually reaches is the CONNECT authority
(HTTPS) or the absolute-URI host (plain HTTP). That is `flow.request.host`,
and it is what the allowlist is checked against.

The Host header and TLS SNI are client-controlled labels and are never used
to decide the destination — an agent could otherwise CONNECT to an arbitrary
host and present an allowlisted Host header. They are checked only as a
consistency constraint: when present, each must sit under the same allowlist
entry as the real destination (anti domain-fronting).

Loaded via: mitmdump --mode regular -s /opt/egress-policy.py
"""

import fnmatch
import logging
import re
from pathlib import Path

from mitmproxy import ctx, http
from mitmproxy.net.http import url

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


def _host_matches_domain(hostname: str, domain: str) -> bool:
    """Match a single hostname against one allowlist entry.

    An entry containing '*' is treated as an fnmatch glob against the full
    hostname (e.g. "*vsblobprod*.blob.core.windows.net" for Azure DevOps package
    blobs, whose storage-account subdomain rotates by region). A plain entry
    matches exactly or as a parent domain (subdomain match)."""
    hostname = hostname.lower().rstrip(".")
    if "*" in domain:
        # Entries are already lowercased at load time; fnmatchcase keeps matching
        # deterministic across platforms (plain fnmatch would apply os.path.normcase).
        return fnmatch.fnmatchcase(hostname, domain)
    return hostname == domain or hostname.endswith("." + domain)


def _is_allowed(hostname: str, allowed: list[str]) -> bool:
    """Check if hostname matches any allowed domain (exact, subdomain, or glob)."""
    return any(_host_matches_domain(hostname, domain) for domain in allowed)


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

    def _same_entry(self, a: str, b: str) -> bool:
        """True if some single allowlist entry covers both hostnames."""
        return any(
            _host_matches_domain(a, d) and _host_matches_domain(b, d)
            for d in self.allowed_domains
        )

    @staticmethod
    def _deny(flow: http.HTTPFlow, msg: str) -> None:
        flow.response = http.Response.make(
            403, f"Egress blocked by sandbox policy: {msg}\n".encode(),
            {"Content-Type": "text/plain"},
        )

    def http_connect(self, flow: http.HTTPFlow):
        """Reject a CONNECT tunnel to a non-allowlisted host before any TLS."""
        dest = flow.request.host
        if not dest or not _is_allowed(dest, self.allowed_domains):
            logger.warning("BLOCKED (CONNECT): %s", dest)
            self._deny(flow, f"CONNECT {dest}")

    def request(self, flow: http.HTTPFlow):
        """Enforce policy on every HTTP(S) request."""
        dest = flow.request.host
        if not dest:
            self._deny(flow, "no destination host")
            return

        if not _is_allowed(dest, self.allowed_domains):
            logger.warning("BLOCKED (dest): %s%s", dest, flow.request.path)
            self._deny(flow, dest)
            return

        # Consistency: Host header and SNI must agree with the real destination.
        host_header = flow.request.host_header
        header_host = url.parse_authority(host_header, check=False)[0] if host_header else ""
        sni = getattr(flow.client_conn, "sni", None) or ""
        for label, value in (("Host", header_host), ("SNI", sni)):
            if not value:
                continue
            value = value.lower().rstrip(".")
            if value == dest.lower().rstrip("."):
                continue
            if not self._same_entry(dest, value):
                logger.warning(
                    "BLOCKED (domain fronting): dest=%s %s=%s", dest, label, value
                )
                self._deny(flow, f"domain fronting (dest={dest}, {label}={value})")
                return

        logger.debug("ALLOWED: %s%s", dest, flow.request.path)


addons = [EgressPolicy()]
