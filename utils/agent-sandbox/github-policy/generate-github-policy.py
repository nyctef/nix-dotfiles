#!/usr/bin/env python3
"""Compile GitHub's own API specs into a write-policy table for the sandbox.

The agent sandbox lets the agent *read* GitHub freely (reads are the prompt-
injection vector, but exfil via read is weak — an attacker can't see GitHub's
access logs). Writes are the exfiltration risk, so we scope them: allow writes
only to an owner allowlist (red-gate), and deny writes that have no identifiable
owner (gists, /user/*, app management, …).

Rather than hand-maintain a regex list that silently rots against the API, we
ground the write classification in GitHub's *own* machine-readable specs:

  - REST:    github/rest-api-description OpenAPI (pinned commit). Every write
             operation (POST/PUT/PATCH/DELETE) is emitted with a path regex, a
             flag for whether it carries an {owner}/{org} we can scope to, its
             operationId, and x-github category.
  - GraphQL: the published public SDL. The single `type Mutation { … }` block
             enumerates every mutation field name; any GraphQL document that
             invokes a `mutation` operation is a write.

Output: github-policy.json — the artifact the mitmproxy addon (github-policy.py)
loads at runtime. It is committed so the diff is reviewable; regenerate with
this script after bumping REST_COMMIT.

Usage:
    python3 generate-github-policy.py            # regenerate github-policy.json
    python3 generate-github-policy.py --check     # fail if the committed file is stale

Stdlib only (urllib/json/re/hashlib) so it runs anywhere, no pip install.
"""

import argparse
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

# ── Pinned sources ────────────────────────────────────────────────────────────
# REST is pinned to a commit for reproducibility; bump this to refresh.
REST_COMMIT = "c7e0478faa2fd2efc21bf72da5227a58ae3d42c9"
REST_URL = (
    "https://raw.githubusercontent.com/github/rest-api-description/"
    f"{REST_COMMIT}/descriptions/api.github.com/api.github.com.json"
)
# GitHub does not expose the GraphQL SDL by commit; we pin by content hash
# (recorded in the output). This is the docs "latest public schema" endpoint.
GRAPHQL_URL = "https://docs.github.com/public/fpt/schema.docs.graphql"

OUTPUT = Path(__file__).with_name("github-policy.json")

WRITE_METHODS = {"post", "put", "patch", "delete"}
# Path params (in placeholder order) that identify a scopable owner.
OWNER_PARAMS = ("owner", "org")


def _fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "agent-sandbox-policy-gen"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def _path_to_regex(path: str) -> tuple[str, bool]:
    """Convert an OpenAPI path template to an anchored regex.

    The first {owner} or {org} placeholder becomes a named group `scope`; all
    other placeholders become non-capturing `[^/]+`. Returns (regex, scoped).
    """
    scoped = False
    out = []
    for part in re.split(r"(\{[^}]+\})", path):
        if part.startswith("{") and part.endswith("}"):
            name = part[1:-1]
            if not scoped and name in OWNER_PARAMS:
                out.append(r"(?P<scope>[^/]+)")
                scoped = True
            else:
                out.append(r"[^/]+")
        else:
            out.append(re.escape(part))
    return "^" + "".join(out) + "$", scoped


def compile_rest(spec: dict) -> list[dict]:
    rules = []
    for path, ops in spec.get("paths", {}).items():
        for method, op in ops.items():
            if method.lower() not in WRITE_METHODS:
                continue
            if not isinstance(op, dict):
                continue
            regex, scoped = _path_to_regex(path)
            xg = op.get("x-github", {}) or {}
            rules.append(
                {
                    "method": method.upper(),
                    "path": path,  # kept for human review of the artifact
                    "regex": regex,
                    "scoped": scoped,
                    "operationId": op.get("operationId", ""),
                    "category": xg.get("category", ""),
                }
            )
    # Longest path first so specific templates win over generic ones.
    rules.sort(key=lambda r: (-r["path"].count("/"), r["path"], r["method"]))
    return rules


def compile_graphql_mutations(sdl: str) -> list[str]:
    """Extract mutation field names from the `type Mutation { … }` block."""
    m = re.search(r"\btype\s+Mutation\b[^{]*\{(.*?)\n\}", sdl, re.DOTALL)
    if not m:
        raise SystemExit("could not locate `type Mutation` block in GraphQL SDL")
    body = m.group(1)
    # Field declarations look like:  fieldName(input: X!): Payload
    # (possibly preceded by a description string / directives). Grab the
    # identifier that is immediately followed by `(` or `:` at field level.
    names = re.findall(r"^\s{2}([A-Za-z_][A-Za-z0-9_]*)\s*[(:]", body, re.MULTILINE)
    return sorted(set(names))


def build() -> dict:
    rest_bytes = _fetch(REST_URL)
    graphql_bytes = _fetch(GRAPHQL_URL)
    spec = json.loads(rest_bytes)
    sdl = graphql_bytes.decode("utf-8")

    rest_rules = compile_rest(spec)
    mutations = compile_graphql_mutations(sdl)

    scoped = sum(1 for r in rest_rules if r["scoped"])
    return {
        "_comment": (
            "GENERATED by generate-github-policy.py — do not edit by hand. "
            "Regenerate after bumping REST_COMMIT. Grounds the sandbox GitHub "
            "write-policy in GitHub's own REST OpenAPI + GraphQL SDL."
        ),
        "generated_from": {
            "rest": {
                "url": REST_URL,
                "commit": REST_COMMIT,
                "sha256": hashlib.sha256(rest_bytes).hexdigest(),
                "openapi": spec.get("openapi"),
            },
            "graphql": {
                "url": GRAPHQL_URL,
                "sha256": hashlib.sha256(graphql_bytes).hexdigest(),
            },
        },
        "stats": {
            "rest_write_rules": len(rest_rules),
            "rest_scoped": scoped,
            "rest_ownerless": len(rest_rules) - scoped,
            "graphql_mutations": len(mutations),
        },
        "rest_writes": rest_rules,
        "graphql_mutations": mutations,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if github-policy.json is missing or stale",
    )
    args = ap.parse_args()

    policy = build()
    rendered = json.dumps(policy, indent=2, ensure_ascii=False) + "\n"

    if args.check:
        if not OUTPUT.exists():
            print(f"MISSING: {OUTPUT}", file=sys.stderr)
            return 1
        current = OUTPUT.read_text()
        # Compare ignoring the source hashes, which drift as upstream moves;
        # the meaningful diff is the rules + mutation set.
        def _core(d):
            return {k: d[k] for k in ("rest_writes", "graphql_mutations")}
        if _core(json.loads(current)) != _core(policy):
            print("STALE: github-policy.json differs from freshly compiled policy", file=sys.stderr)
            return 1
        print("OK: github-policy.json is up to date")
        return 0

    OUTPUT.write_text(rendered)
    s = policy["stats"]
    print(f"Wrote {OUTPUT}")
    print(
        f"  REST: {s['rest_write_rules']} write rules "
        f"({s['rest_scoped']} owner-scoped, {s['rest_ownerless']} ownerless)"
    )
    print(f"  GraphQL: {s['graphql_mutations']} mutation fields")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
