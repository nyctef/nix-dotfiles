"""mitmproxy addon: GitHub write-scoping for the agent sandbox.

Runs in the sidecar alongside egress-policy.py (hostname allowlist) and
cred-inject.py (credential injection). Load order matters: this addon must run
*before* cred-inject.py so a blocked write never gets a real credential attached
(see sidecar-entrypoint.sh).

Goal — mitigate the blast radius of prompt injection, not prevent it:
  - Reads (GET/HEAD) to GitHub stay open. Reads are the injection vector, but
    exfil via read is weak (an attacker can't see GitHub's access logs).
  - Writes (POST/PUT/PATCH/DELETE, git push, GraphQL mutations) are scoped to an
    owner allowlist (github-write-allowed-owners.txt, e.g. red-gate). Writes to
    any other owner — and owner-less writes like gists / /user/* — are blocked.

The classification is grounded in GitHub's own specs, compiled offline by
generate-github-policy.py into github-policy.json:
  - REST:    per-operation path regex + whether it carries a scopable owner.
  - GraphQL: the authoritative set of mutation field names.

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
from pathlib import Path

logger = logging.getLogger(__name__)

POLICY_FILE = "/opt/github-policy.json"
OWNERS_FILE = "/etc/github-write-allowed-owners.txt"

ALLOW, DENY, PASS = "ALLOW", "DENY", "PASS"

_READ_METHODS = {"GET", "HEAD", "OPTIONS"}


def _load_owners(path: str) -> set[str]:
    owners: set[str] = set()
    p = Path(path)
    if not p.exists():
        logger.error("GitHub write-owner allowlist not found: %s (all writes will be denied)", path)
        return owners
    for line in p.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            owners.add(line.lower())
    return owners


def _strip_graphql(query: str) -> str:
    """Remove comments and string literals so keyword scanning is reliable."""
    query = re.sub(r'"""(?:.|\n)*?"""', " ", query)        # block strings
    query = re.sub(r'"(?:\\.|[^"\\])*"', " ", query)         # normal strings
    query = re.sub(r"#[^\n]*", " ", query)                   # comments
    return query


# A GraphQL document runs a mutation only if it declares a top-level `mutation`
# operation. Shorthand `{ … }` documents are always queries. Matching the
# `mutation` operation keyword (after stripping strings/comments) is sound for
# detection; false positives merely block a read (fail-closed, acceptable).
_MUTATION_OP = re.compile(r"(?:^|[\s})])mutation\b\s*[A-Za-z_]*\s*[({@]")


class GitHubPolicy:
    def __init__(self, policy_file: str = POLICY_FILE, owners_file: str = OWNERS_FILE):
        self.allowed_owners: set[str] = _load_owners(owners_file)
        self.rest_rules: list[dict] = []
        self.mutation_fields: set[str] = set()
        self._compiled: list[tuple] = []  # (method, compiled_regex, scoped, opid, category)
        self._load_policy(policy_file)

    # ── config ────────────────────────────────────────────────────────────────
    def _load_policy(self, path: str):
        p = Path(path)
        if not p.exists():
            logger.error("GitHub policy file not found: %s (all GitHub writes denied)", path)
            return
        data = json.loads(p.read_text())
        self.rest_rules = data.get("rest_writes", [])
        self.mutation_fields = set(data.get("graphql_mutations", []))
        self._compiled = [
            (r["method"], re.compile(r["regex"]), r["scoped"], r.get("operationId", ""), r.get("category", ""))
            for r in self.rest_rules
        ]
        logger.info(
            "GitHub policy loaded: %d REST write rules, %d mutations, owners=%s",
            len(self._compiled),
            len(self.mutation_fields),
            sorted(self.allowed_owners) or "<none>",
        )

    # ── host classification ─────────────────────────────────────────────────
    @staticmethod
    def is_github_host(host: str) -> bool:
        host = host.lower().rstrip(".")
        return (
            host == "github.com"
            or host.endswith(".github.com")
            or host.endswith(".githubusercontent.com")
        )

    def _owner_ok(self, owner: str | None, what: str) -> tuple[str, str]:
        if not owner:
            return DENY, f"{what}: no identifiable owner"
        if owner.lower() in self.allowed_owners:
            return ALLOW, f"{what}: owner '{owner}' allowed"
        return DENY, f"{what}: owner '{owner}' not in write allowlist"

    # ── the decision ──────────────────────────────────────────────────────────
    def classify(self, host: str, method: str, path: str, body_text: str = "") -> tuple[str, str]:
        """Return (verdict, reason). Pure — no mitmproxy dependency."""
        host = host.lower().rstrip(".")
        method = method.upper()

        if not self.is_github_host(host):
            return PASS, "not a github host"

        if method in _READ_METHODS:
            return ALLOW, "read method"

        # git smart-HTTP (not covered by either spec — handled structurally).
        # Advertisement (/info/refs) is a GET, handled above; the POST bodies:
        #   git-upload-pack  = fetch/clone  → read, allow to any owner
        #   git-receive-pack = push         → write, scope to owner
        if path.endswith("/git-upload-pack"):
            return ALLOW, "git fetch (upload-pack)"
        if path.endswith("/git-receive-pack"):
            owner = self._first_segment(path)
            return self._owner_ok(owner, "git push")

        # GraphQL — always POST to /graphql; body determines read vs write.
        if host == "api.github.com" and path.split("?", 1)[0].rstrip("/") == "/graphql":
            return self._classify_graphql(body_text)

        # REST writes on the API host — grounded in the compiled OpenAPI table.
        if host == "api.github.com":
            return self._classify_rest(method, path.split("?", 1)[0])

        # Other GitHub hosts (uploads.github.com release assets, github.com web,
        # *.githubusercontent.com). Not in the OpenAPI table; extract an owner
        # structurally, else deny (nothing legitimately writes to the CDNs).
        owner = self._structural_owner(path)
        if owner is not None:
            return self._owner_ok(owner, f"{method} {host}")
        return DENY, f"{method} {host}{path}: write with no identifiable owner"

    def _classify_rest(self, method: str, path: str) -> tuple[str, str]:
        for m, rx, scoped, opid, category in self._compiled:
            if m != method:
                continue
            match = rx.match(path)
            if not match:
                continue
            if scoped:
                return self._owner_ok(match.group("scope"), f"REST {opid or category}")
            return DENY, f"REST {opid or path}: owner-less write endpoint"
        # No documented write operation matched — fail closed.
        return DENY, f"REST {method} {path}: unknown write endpoint (default-deny)"

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
            return DENY, "graphql: mutation operation (not owner-scopable, default-deny)"
        return ALLOW, "graphql: query only"

    # ── path helpers ──────────────────────────────────────────────────────────
    @staticmethod
    def _first_segment(path: str) -> str | None:
        parts = [p for p in path.lstrip("/").split("/") if p]
        return parts[0] if parts else None

    @staticmethod
    def _structural_owner(path: str) -> str | None:
        m = re.match(r"^/(?:repos|orgs|users)/([^/]+)/", path)
        return m.group(1) if m else None


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
            # Reading the body forces mitmproxy to buffer it, which we only want
            # for the GraphQL endpoint; keep it cheap elsewhere.
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
