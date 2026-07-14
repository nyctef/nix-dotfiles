"""mitmproxy addon: GitHub read-only enforcement for the agent sandbox.

Runs in the sidecar alongside egress-policy.py (hostname allowlist) and
cred-inject.py (credential injection). Load order matters: this addon must run
*before* cred-inject.py so a blocked write never gets a real credential attached
(see sidecar-entrypoint.sh).

Goal — mitigate the blast radius of prompt injection, not prevent it:
  - Reads (GET/HEAD) to GitHub stay open. Reads are the injection vector, but
    exfil via read is weak (an attacker can't see GitHub's access logs).
  - Writes are blocked wholesale. Anything that isn't a plain read — every
    POST/PUT/PATCH/DELETE and git push — is denied.

The only exceptions are:
  - git's fetch/clone path: `POST .../git-upload-pack` is how the smart-HTTP
    protocol serves a clone or fetch, so it is a read and is allowed.
    `git-receive-pack` (push) falls through to deny.
  - GraphQL: `POST /graphql` is inspected. Top-level `query` operations are
    allowed; top-level `mutation` operations are denied. This lets gh CLI
    porcelain that reads via GraphQL work in-sandbox.

`GitHubPolicy` is pure (no mitmproxy imports in the hot path) so it can be unit
tested directly; the module-level `addons` wires it into mitmproxy.

Verdicts:
  ALLOW  — let the request through.
  DENY   — respond 403 from the sidecar; the request never leaves.
  PASS   — not a GitHub host; not our concern (egress-policy.py still applies).
"""

import json
import logging
import re

logger = logging.getLogger(__name__)

ALLOW, DENY, PASS = "ALLOW", "DENY", "PASS"

_READ_METHODS = {"GET", "HEAD", "OPTIONS"}


def _strip_graphql(query: str) -> str:
    """Remove comments and string literals so keyword scanning is reliable."""
    query = re.sub(r'"""(?:.|\n)*?"""', " ", query)   # block strings
    query = re.sub(r'"(?:\\.|[^"\\])*"', " ", query)  # normal strings
    query = re.sub(r"#[^\n]*", " ", query)              # line comments
    return query


# Matches a top-level `mutation` operation keyword. Shorthand `{ … }` documents
# are always queries. Matching `mutation` after stripping strings/comments is
# sound; false positives (a query that mentions the word) merely block a read
# (fail-closed, acceptable).
_MUTATION_OP = re.compile(r"(?:^|[\s})])mutation\b\s*[A-Za-z_]*\s*[({@]")


class GitHubPolicy:
    # ── host classification ─────────────────────────────────────────────────
    @staticmethod
    def is_github_host(host: str) -> bool:
        host = host.lower().rstrip(".")
        return (
            host == "github.com"
            or host.endswith(".github.com")
            or host.endswith(".githubusercontent.com")
        )

    # ── the decision ──────────────────────────────────────────────────────────
    def classify(self, host: str, method: str, path: str, body_text: str = "") -> tuple[str, str]:
        """Return (verdict, reason). Pure — no mitmproxy dependency."""
        host = host.lower().rstrip(".")
        method = method.upper()

        if not self.is_github_host(host):
            return PASS, "not a github host"

        if method in _READ_METHODS:
            return ALLOW, "read method"

        # git smart-HTTP fetch/clone: the /info/refs advertisement is a GET
        # (allowed above); the follow-up POST carries git-upload-pack, which is
        # still a read. git-receive-pack (push) falls through to the deny below.
        if path.split("?", 1)[0].endswith("/git-upload-pack"):
            return ALLOW, "git fetch (upload-pack)"

        # GraphQL: POST to /graphql — inspect the body to distinguish queries
        # (reads, allowed) from mutations (writes, denied).
        if host == "api.github.com" and path.split("?", 1)[0].rstrip("/") == "/graphql":
            return self._classify_graphql(body_text)

        # Everything else is a write (REST mutations, git push).
        return DENY, f"{method} {host}{path}: write blocked (GitHub is read-only in sandbox)"

    def _classify_graphql(self, body_text: str) -> tuple[str, str]:
        if not body_text:
            return DENY, "graphql: empty body (default-deny)"
        query = ""
        try:
            payload = json.loads(body_text)
            if isinstance(payload, list):  # batched queries
                query = "\n".join(str(item.get("query", "")) for item in payload if isinstance(item, dict))
            elif isinstance(payload, dict):
                query = str(payload.get("query", ""))
        except (ValueError, TypeError):
            return DENY, "graphql: unparseable body (default-deny)"
        if not query:
            return DENY, "graphql: no query field (default-deny)"
        if _MUTATION_OP.search(_strip_graphql(query)):
            return DENY, "graphql: mutation operation blocked"
        return ALLOW, "graphql: query only"


# ── mitmproxy integration ───────────────────────────────────────────────────
try:
    from mitmproxy import http

    class _Addon:
        def __init__(self):
            self.policy = GitHubPolicy()

        def request(self, flow: "http.HTTPFlow"):
            if flow.response:  # already decided by an earlier addon
                return
            host = flow.request.pretty_host
            if not host or not GitHubPolicy.is_github_host(host):
                return

            # Read the body only for the GraphQL endpoint — buffering the body
            # of every POST would be wasteful for large git pushes etc.
            body_text = ""
            path_only = flow.request.path.split("?", 1)[0].rstrip("/")
            if host.lower() == "api.github.com" and path_only == "/graphql":
                body_text = flow.request.get_text(strict=False) or ""

            verdict, reason = self.policy.classify(
                host, flow.request.method, flow.request.path, body_text
            )
            if verdict == DENY:
                logger.warning("GITHUB-WRITE BLOCKED: %s %s%s — %s",
                               flow.request.method, host, flow.request.path, reason)
                flow.response = http.Response.make(
                    403,
                    (f"Egress blocked by sandbox GitHub write-policy: {reason}\n").encode(),
                    {"Content-Type": "text/plain"},
                )
            else:
                logger.debug("GITHUB %s: %s %s%s — %s",
                             verdict, flow.request.method, host, flow.request.path, reason)

    addons = [_Addon()]
except ImportError:
    # Imported for unit testing without mitmproxy installed.
    addons = []
