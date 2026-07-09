#!/usr/bin/env python3
"""Unit tests for the GitHub write-policy classifier (github-policy.py).

Pure-stdlib, no mitmproxy needed. Run:  python3 test-github-policy.py
Exit code = number of failed assertions.
"""

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent  # utils/agent-sandbox

# Load github-policy.py as a module (the mitmproxy import is optional there).
spec = importlib.util.spec_from_file_location("github_policy", ROOT / "github-policy.py")
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)

policy = gp.GitHubPolicy(
    policy_file=str(HERE / "github-policy.json"),
    owners_file=str(ROOT / "github-write-allowed-owners.txt"),
)

ALLOW, DENY, PASS = gp.ALLOW, gp.DENY, gp.PASS

fails = 0


def check(expected, host, method, path, body="", note=""):
    global fails
    verdict, reason = policy.classify(host, method, path, body)
    ok = verdict == expected
    mark = "✓" if ok else "✗"
    if not ok:
        fails += 1
    print(f"  {mark} [{verdict:5}] {method:6} {host}{path}  {note}")
    if not ok:
        print(f"      expected {expected}, got {verdict} — {reason}")


print("Reads are always allowed:")
check(ALLOW, "api.github.com", "GET", "/repos/nyctef/nix-dotfiles/issues")
check(ALLOW, "github.com", "GET", "/nyctef/nix-dotfiles")
check(ALLOW, "raw.githubusercontent.com", "GET", "/nyctef/x/main/f")
check(ALLOW, "api.github.com", "HEAD", "/user")

print("\nREST writes scoped to owner allowlist (red-gate):")
check(ALLOW, "api.github.com", "POST", "/repos/red-gate/tool/issues", note="issue in red-gate → allow")
check(DENY, "api.github.com", "POST", "/repos/nyctef/nix-dotfiles/issues", note="THE test: issue in nyctef → block")
check(DENY, "api.github.com", "PATCH", "/repos/someoneelse/repo", note="edit foreign repo → block")
check(ALLOW, "api.github.com", "DELETE", "/repos/red-gate/repo/issues/comments/1", note="delete in red-gate → allow")
check(ALLOW, "api.github.com", "POST", "/orgs/red-gate/repos", note="create repo in red-gate org → allow")
check(DENY, "api.github.com", "POST", "/orgs/evilorg/repos", note="create repo in foreign org → block")

print("\nOwner-less writes are always denied (exfil channels):")
check(DENY, "api.github.com", "POST", "/gists", note="create gist")
check(DENY, "api.github.com", "POST", "/user/repos", note="create repo for user")
check(DENY, "api.github.com", "PATCH", "/user", note="edit profile")
check(DENY, "api.github.com", "POST", "/markdown", note="not in allowlist → default-deny")

print("\nUnknown write endpoints fail closed:")
check(DENY, "api.github.com", "POST", "/some/undocumented/endpoint")

print("\ngit smart-HTTP:")
check(ALLOW, "github.com", "POST", "/nyctef/nix-dotfiles.git/git-upload-pack", note="clone/fetch any → allow")
check(ALLOW, "github.com", "GET", "/nyctef/nix-dotfiles.git/info/refs?service=git-upload-pack", note="advert → allow")
check(DENY, "github.com", "POST", "/nyctef/nix-dotfiles.git/git-receive-pack", note="push to nyctef → block")
check(ALLOW, "github.com", "POST", "/red-gate/tool.git/git-receive-pack", note="push to red-gate → allow")

print("\nGraphQL: queries allowed, mutations denied:")
check(ALLOW, "api.github.com", "POST", "/graphql", '{"query":"query { viewer { login } }"}', "read query")
check(ALLOW, "api.github.com", "POST", "/graphql", '{"query":"{ viewer { login } }"}', "shorthand query")
check(DENY, "api.github.com", "POST", "/graphql",
      '{"query":"mutation { addComment(input:{subjectId:\\"x\\",body:\\"y\\"}) { clientMutationId } }"}',
      "mutation → block")
check(DENY, "api.github.com", "POST", "/graphql",
      '{"query":"mutation CreateIt { createIssue(input:{}) { issue { id } } }"}', "named mutation → block")
check(ALLOW, "api.github.com", "POST", "/graphql",
      '{"query":"query { search(query:\\"mutation stuff\\", type:ISSUE) { issueCount } }"}',
      "'mutation' as a string literal → still a query")
check(DENY, "api.github.com", "POST", "/graphql", "not json", "unparseable → deny")

print("\nuploads.github.com (release assets) scoped structurally:")
check(ALLOW, "uploads.github.com", "POST", "/repos/red-gate/tool/releases/1/assets?name=x", note="→ allow")
check(DENY, "uploads.github.com", "POST", "/repos/nyctef/x/releases/1/assets?name=x", note="→ block")

print("\nNon-github hosts pass through (egress-policy handles them):")
check(PASS, "api.anthropic.com", "POST", "/v1/messages")
check(PASS, "red-gate.pkgs.visualstudio.com", "PUT", "/_packaging/x")

print()
if fails:
    print(f"FAILED: {fails} assertion(s)")
else:
    print("All classifier assertions passed.")
sys.exit(fails)
