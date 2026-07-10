"""mitmproxy addon: GitHub read-only enforcement for the agent sandbox.

Runs in the sidecar alongside egress-policy.py (hostname allowlist) and
cred-inject.py (credential injection). Load order matters: this addon must run
*before* cred-inject.py so a blocked write never gets a real credential attached
(see sidecar-entrypoint.sh).

Goal — mitigate the blast radius of prompt injection, not prevent it:
  - Reads (GET/HEAD) to GitHub stay open. Reads are the injection vector, but
    exfil via read is weak (an attacker can't see GitHub's access logs).
  - Writes are blocked wholesale. Anything that isn't a plain read — every
    POST/PUT/PATCH/DELETE, git push, and GraphQL POST — is denied.

The only exception is git's fetch/clone path: `POST .../git-upload-pack` is how
the smart-HTTP protocol serves a clone or fetch, so it is a read and is allowed.
`git-receive-pack` (push) and everything else are denied.

Note the deliberate coarseness: GraphQL read queries are POSTs, so they are
blocked too. gh CLI porcelain that reads via GraphQL will fail in-sandbox; use a
REST GET (gh api -X GET / plain GET) or run those workflows outside the sandbox.

`GitHubPolicy` is pure (no mitmproxy imports in the hot path) so it can be unit
tested directly; the module-level `addons` wires it into mitmproxy.

Verdicts:
  ALLOW  — let the request through.
  DENY   — respond 403 from the sidecar; the request never leaves.
  PASS   — not a GitHub host; not our concern (egress-policy.py still applies).
"""

import logging

logger = logging.getLogger(__name__)

ALLOW, DENY, PASS = "ALLOW", "DENY", "PASS"

_READ_METHODS = {"GET", "HEAD", "OPTIONS"}


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
    def classify(self, host: str, method: str, path: str) -> tuple[str, str]:
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

        # Everything else is a write (REST mutations, git push, GraphQL POST).
        return DENY, f"{method} {host}{path}: write blocked (GitHub is read-only in sandbox)"


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

            verdict, reason = self.policy.classify(
                host, flow.request.method, flow.request.path
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
