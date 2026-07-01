"""
mitmproxy addon: credential injection for the agent sandbox (Phase C).

Runs in the sidecar proxy alongside egress-policy.py. Intercepts outbound
requests from the agent container and injects real credentials, replacing
placeholder tokens that the agent holds. Real credentials are in the sidecar's
environment (set by the launcher); they never enter the agent container.

Injection modes:
  - github:     auto-detects API vs git HTTPS. API gets "token <PAT>", git gets
                "Basic <base64(x-access-token:<PAT>)>".
  - basic_auth: replaces placeholder in Basic auth with real PAT.
  - header:     sets a specific header to the real credential value.

The credential map is loaded from /etc/credential-map.yaml (COPY'd into the
sidecar image). Real credential values come from SANDBOX_CRED_* env vars.

Loaded via: mitmdump ... -s /opt/cred-inject.py
"""

import base64
import logging
import os
import re
from pathlib import Path

import yaml
from mitmproxy import ctx, http

logger = logging.getLogger(__name__)

CREDENTIAL_MAP_FILE = "/etc/credential-map.yaml"


class ServiceConfig:
    """Parsed config for one service from credential-map.yaml."""

    __slots__ = (
        "name",
        "domains",
        "env_var",
        "placeholder",
        "mode",
        "header_name",
        "real_credential",
    )

    def __init__(
        self,
        name: str,
        domains: list[str],
        env_var: str,
        placeholder: str,
        mode: str,
        header_name: str | None,
    ):
        self.name = name
        self.domains = [d.lower() for d in domains]
        self.env_var = env_var
        self.placeholder = placeholder
        self.mode = mode
        self.header_name = header_name
        self.real_credential = ""


def _domain_matches(hostname: str, domains: list[str]) -> bool:
    """Check if hostname matches any domain (exact or subdomain)."""
    hostname = hostname.lower().rstrip(".")
    for domain in domains:
        if hostname == domain or hostname.endswith("." + domain):
            return True
    return False


class CredentialInjector:
    def __init__(self):
        self.services: list[ServiceConfig] = []

    def load(self, loader):
        loader.add_option(
            name="credential_map_file",
            typespec=str,
            default=CREDENTIAL_MAP_FILE,
            help="Path to the credential map YAML file",
        )

    def configure(self, updated):
        path = ctx.options.credential_map_file
        self._load_config(path)

    def _load_config(self, path: str):
        """Load credential map and resolve env vars."""
        p = Path(path)
        if not p.exists():
            logger.warning("Credential map not found: %s — injection disabled", path)
            return

        try:
            data = yaml.safe_load(p.read_text())
        except Exception as e:
            logger.error("Failed to parse credential map %s: %s", path, e)
            return

        services_data = data.get("services", {})
        self.services = []
        active_count = 0

        for name, svc in services_data.items():
            if not isinstance(svc, dict):
                continue

            inject = svc.get("inject", {})
            config = ServiceConfig(
                name=name,
                domains=svc.get("domains", []),
                env_var=svc.get("env_var", ""),
                placeholder=svc.get("placeholder", ""),
                mode=inject.get("mode", "header"),
                header_name=inject.get("header_name"),
            )

            # Resolve the real credential from the sidecar's environment.
            real = os.environ.get(config.env_var, "")
            if real:
                config.real_credential = real
                active_count += 1
                logger.info(
                    "Credential injection active: %s (%d domains, mode=%s)",
                    name,
                    len(config.domains),
                    config.mode,
                )
            else:
                logger.info(
                    "Credential injection inactive: %s (%s not set)",
                    name,
                    config.env_var,
                )

            self.services.append(config)

        logger.info(
            "Credential injector loaded: %d services (%d active) from %s",
            len(self.services),
            active_count,
            path,
        )

    def request(self, flow: http.HTTPFlow):
        """Inject credentials into matching outbound requests."""
        host = flow.request.pretty_host
        if not host:
            return

        # First pass: inject real credentials for active services.
        injected = False
        for svc in self.services:
            if not svc.real_credential:
                continue
            if not _domain_matches(host, svc.domains):
                continue

            if svc.mode == "github":
                self._inject_github(flow, svc)
            elif svc.mode == "basic_auth":
                self._inject_basic_auth(flow, svc)
            elif svc.mode == "header":
                self._inject_header(flow, svc)
            elif svc.mode == "bearer":
                self._inject_bearer(flow, svc)
            else:
                logger.warning(
                    "Unknown injection mode '%s' for service %s",
                    svc.mode,
                    svc.name,
                )
            injected = True
            break  # Only one service per request

        # Second pass: strip placeholder tokens from inactive services that
        # match this domain. Example: the agent always sends CLAUDE_CODE_OAUTH_TOKEN
        # (a placeholder) but when only ANTHROPIC_API_KEY is configured, the
        # placeholder Bearer token must be stripped so it doesn't conflict with
        # the x-api-key header injected above.
        for svc in self.services:
            if svc.real_credential:
                continue  # Active service — already handled above.
            if not svc.placeholder:
                continue
            if not _domain_matches(host, svc.domains):
                continue
            self._strip_placeholder(flow, svc)

    def _inject_github(self, flow: http.HTTPFlow, svc: ServiceConfig):
        """GitHub: API gets 'token <PAT>', git HTTPS gets Basic auth."""
        auth_header = flow.request.headers.get("Authorization", "")
        user_agent = flow.request.headers.get("User-Agent", "")
        path = flow.request.path

        # Detect git HTTPS by User-Agent or URL patterns.
        is_git = (
            "git/" in user_agent.lower()
            or "/info/refs" in path
            or "/git-upload-pack" in path
            or "/git-receive-pack" in path
        )

        if is_git:
            # git sends: Basic <base64(x-access-token:<placeholder>)>
            # Replace with: Basic <base64(x-access-token:<real>)>
            real_b64 = base64.b64encode(
                f"x-access-token:{svc.real_credential}".encode()
            ).decode()
            flow.request.headers["Authorization"] = f"Basic {real_b64}"
            logger.debug("Injected GitHub git credential for %s%s", flow.request.pretty_host, path)
        else:
            # API: replace placeholder token or set outright.
            if svc.placeholder and svc.placeholder in auth_header:
                flow.request.headers["Authorization"] = auth_header.replace(
                    svc.placeholder, svc.real_credential
                )
            else:
                # No placeholder found — inject unconditionally.
                flow.request.headers["Authorization"] = (
                    f"token {svc.real_credential}"
                )
            logger.debug("Injected GitHub API credential for %s%s", flow.request.pretty_host, path)

    def _inject_basic_auth(self, flow: http.HTTPFlow, svc: ServiceConfig):
        """Replace placeholder PAT in Basic auth header."""
        auth_header = flow.request.headers.get("Authorization", "")

        if svc.placeholder and svc.placeholder in auth_header:
            # The header contains the placeholder — swap it.
            flow.request.headers["Authorization"] = auth_header.replace(
                svc.placeholder, svc.real_credential
            )
            logger.debug(
                "Injected %s Basic auth credential (placeholder swap) for %s",
                svc.name,
                flow.request.pretty_host,
            )
        elif auth_header.lower().startswith("basic "):
            # Decode, check for placeholder in the decoded value, re-encode.
            try:
                decoded = base64.b64decode(auth_header[6:]).decode("utf-8", errors="replace")
                if svc.placeholder and svc.placeholder in decoded:
                    replaced = decoded.replace(svc.placeholder, svc.real_credential)
                    new_b64 = base64.b64encode(replaced.encode()).decode()
                    flow.request.headers["Authorization"] = f"Basic {new_b64}"
                    logger.debug(
                        "Injected %s Basic auth credential (b64 placeholder swap) for %s",
                        svc.name,
                        flow.request.pretty_host,
                    )
            except Exception:
                pass
        else:
            # No auth header — inject one. NuGet uses "PAT" as the username
            # in some flows; use a generic user.
            cred_b64 = base64.b64encode(
                f"sandbox:{svc.real_credential}".encode()
            ).decode()
            flow.request.headers["Authorization"] = f"Basic {cred_b64}"
            logger.debug(
                "Injected %s Basic auth credential (new header) for %s",
                svc.name,
                flow.request.pretty_host,
            )

    def _inject_bearer(self, flow: http.HTTPFlow, svc: ServiceConfig):
        """Replace placeholder Bearer token in Authorization header."""
        auth_header = flow.request.headers.get("Authorization", "")

        if svc.placeholder and svc.placeholder in auth_header:
            # Placeholder swap within the existing header.
            flow.request.headers["Authorization"] = auth_header.replace(
                svc.placeholder, svc.real_credential
            )
            logger.debug(
                "Injected %s Bearer credential (placeholder swap) for %s",
                svc.name,
                flow.request.pretty_host,
            )
        elif auth_header.lower().startswith("bearer ") and svc.placeholder and svc.placeholder in auth_header:
            # Already covered above, but explicit for clarity.
            pass
        elif not auth_header:
            # No auth header — inject one.
            flow.request.headers["Authorization"] = (
                f"Bearer {svc.real_credential}"
            )
            logger.debug(
                "Injected %s Bearer credential (new header) for %s",
                svc.name,
                flow.request.pretty_host,
            )
        else:
            # Auth header exists but doesn't contain our placeholder — don't
            # clobber it. It may be from another service (e.g. x-api-key is
            # handled by the 'header' mode for the same domain).
            pass

    def _strip_placeholder(self, flow: http.HTTPFlow, svc: ServiceConfig):
        """Remove placeholder tokens from requests when the real credential is
        not available. Prevents stale placeholder values from reaching the
        upstream API and causing auth conflicts."""
        auth_header = flow.request.headers.get("Authorization", "")
        if svc.placeholder and svc.placeholder in auth_header:
            del flow.request.headers["Authorization"]
            logger.debug(
                "Stripped placeholder %s Authorization header for %s",
                svc.name,
                flow.request.pretty_host,
            )

    def _inject_header(self, flow: http.HTTPFlow, svc: ServiceConfig):
        """Set a specific header to the real credential value."""
        header_name = svc.header_name
        if not header_name:
            logger.warning(
                "Service %s: mode=header but no header_name configured",
                svc.name,
            )
            return

        existing = flow.request.headers.get(header_name, "")

        if svc.placeholder and svc.placeholder in existing:
            # Placeholder swap within the existing header value.
            flow.request.headers[header_name] = existing.replace(
                svc.placeholder, svc.real_credential
            )
        else:
            # Set the header to the real credential.
            flow.request.headers[header_name] = svc.real_credential

        logger.debug(
            "Injected %s header '%s' for %s",
            svc.name,
            header_name,
            flow.request.pretty_host,
        )


addons = [CredentialInjector()]
