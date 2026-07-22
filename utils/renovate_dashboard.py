#!/usr/bin/env python3
"""
Summarize Renovate activity across a list of GitHub repos:
  1. Open PRs authored by the redgate-renovate app.
  2. Counts of queued updates per stage, from each repo's "Dependency Dashboard" issue.
"""

import json
import re
import subprocess
import sys

ORG = "red-gate"
REPOS = [
    "SQLCompareEngine",
    "SQLCompareUIs",
    "RgCompare",
    "OracleTools",
    "SourceControlForOracle",
    "SchemaDataCompareForOracleUIs",
    "ConnectionStringConverter",
    "SQLBackupReader",
]

RENOVATE_AUTHOR = "app/redgate-renovate"

# These stages are already fully represented by open PRs (each is annotated
# with its stage in the PR list), so listing their counts again here would
# just duplicate that information.
STAGES_SHOWN_VIA_PR_LIST = {"Open", "Edited/Blocked"}

SECTION_HEADER_RE = re.compile(r"^##\s+(.*)")
CHECKBOX_RE = re.compile(r"^\s*-\s*\[[ xX]\]\s*<!--\s*(.*?)\s*-->")

# Renovate tags each checkbox with an HTML comment identifying the action it
# triggers and, for per-branch checkboxes, the branch name, e.g.
# "<!-- unlimit-branch=foo -->" or "<!-- rebase-branch=foo -->". That comment
# is a reliable way to tell a genuine queued-update checkbox apart from a
# repo-wide bulk action ("create-all-rate-limited-prs", "rebase-all-open-prs",
# "manual job", ...) - it is NOT a reliable stage label by itself, since the
# same action (e.g. "rebase-branch") is reused across different sections
# (both "Open" and "Edited/Blocked" offer a rebase checkbox). So the stage is
# still taken from the enclosing "## Section" heading; the comment is only
# used to confirm the line is a real per-branch entry.
BRANCH_ACTION_RE = re.compile(r"^[a-zA-Z]+-branch=(.+)$")

# GitHub's combined status-check state per commit, collapsed to a simpler label.
STATUS_ROLLUP_LABEL = {
    "SUCCESS": "Build succeeded",
    "FAILURE": "Build failed",
    "ERROR": "Build failed",
    "PENDING": "Building",
    "EXPECTED": "Building",
}


def run_gh(args):
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        return None, result.stderr.strip()
    return result.stdout, None


def get_open_renovate_prs(repo):
    out, err = run_gh([
        "pr", "list",
        "--repo", f"{ORG}/{repo}",
        "--author", RENOVATE_AUTHOR,
        "--state", "open",
        "--json", "number,title,url,headRefName",
    ])
    if err is not None:
        return None, err
    return json.loads(out), None


def get_dependency_dashboard_body(repo):
    out, err = run_gh([
        "issue", "list",
        "--repo", f"{ORG}/{repo}",
        "--search", '"Dependency Dashboard" in:title',
        "--state", "open",
        "--json", "number,title,url",
    ])
    if err is not None:
        return None, None, err
    issues = json.loads(out)
    if not issues:
        return None, None, "no open 'Dependency Dashboard' issue found"
    issue = issues[0]

    out, err = run_gh([
        "issue", "view", str(issue["number"]),
        "--repo", f"{ORG}/{repo}",
        "--json", "body",
        "-q", ".body",
    ])
    if err is not None:
        return issue, None, err
    return issue, out, None


def parse_dashboard_stages(body):
    """Walk the dashboard markdown. Returns (counts, branch_to_stage):
    - counts: number of genuine per-branch checkboxes per "## Section" stage.
    - branch_to_stage: branch name -> stage, for annotating PRs later.
    Per-branch checkboxes are identified via their
    "<!-- action-branch=name -->" comment, which also gives the branch name."""
    counts = {}
    branch_to_stage = {}
    current_section = None
    for line in body.splitlines():
        header_match = SECTION_HEADER_RE.match(line)
        if header_match:
            current_section = header_match.group(1).strip()
            if current_section == "Detected dependencies":
                # Everything after this is dependency inventory, not queued updates.
                break
            continue
        if current_section is None:
            continue
        checkbox_match = CHECKBOX_RE.match(line)
        if not checkbox_match:
            continue
        comment = checkbox_match.group(1)
        action_match = BRANCH_ACTION_RE.match(comment)
        if not action_match:
            continue
        branch_name = action_match.group(1)
        counts[current_section] = counts.get(current_section, 0) + 1
        branch_to_stage[branch_name] = current_section
    return counts, branch_to_stage


def get_status_rollups(repo_prs):
    """repo_prs: list of (repo, pr_number) pairs. Returns {(repo, pr_number): rollup_state_or_None}
    in a single batched GraphQL call, using aliases to fetch every PR's combined
    commit status/check-run rollup at once instead of one REST call per PR."""
    if not repo_prs:
        return {}

    repos = sorted({repo for repo, _ in repo_prs})
    repo_alias = {repo: f"repo{i}" for i, repo in enumerate(repos)}
    prs_by_repo = {repo: [] for repo in repos}
    for repo, number in repo_prs:
        prs_by_repo[repo].append(number)

    query_parts = ["query {"]
    for repo, ralias in repo_alias.items():
        query_parts.append(f'  {ralias}: repository(owner: "{ORG}", name: "{repo}") {{')
        for i, number in enumerate(prs_by_repo[repo]):
            query_parts.append(f"    pr{i}: pullRequest(number: {number}) {{")
            query_parts.append("      number")
            query_parts.append("      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }")
            query_parts.append("    }")
        query_parts.append("  }")
    query_parts.append("}")
    query = "\n".join(query_parts)

    result = subprocess.run(
        ["gh", "api", "graphql", "-F", "query=@-"],
        input=query, capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None

    data = json.loads(result.stdout)["data"]
    rollups = {}
    for repo, ralias in repo_alias.items():
        repo_data = data[ralias]
        for i, number in enumerate(prs_by_repo[repo]):
            pr_data = repo_data[f"pr{i}"]
            nodes = pr_data["commits"]["nodes"]
            state = nodes[0]["commit"]["statusCheckRollup"]["state"] if nodes and nodes[0]["commit"]["statusCheckRollup"] else None
            rollups[(repo, number)] = state
    return rollups


def main():
    per_repo = {}
    for repo in REPOS:
        prs, prs_err = get_open_renovate_prs(repo)
        issue, body, dashboard_err = get_dependency_dashboard_body(repo)
        counts, branch_to_stage = (parse_dashboard_stages(body) if body else ({}, {}))
        per_repo[repo] = {
            "prs": prs or [],
            "prs_err": prs_err,
            "issue": issue,
            "dashboard_err": dashboard_err,
            "counts": counts,
            "branch_to_stage": branch_to_stage,
        }

    repo_prs = [
        (repo, pr["number"])
        for repo, info in per_repo.items()
        for pr in info["prs"]
    ]
    rollups = get_status_rollups(repo_prs)
    if rollups is None:
        print("[warning] failed to fetch PR status checks via GraphQL; build status will be omitted")
        rollups = {}

    for repo, info in per_repo.items():
        print(f"\n=== {ORG}/{repo} ===")

        if info["prs_err"] is not None:
            print(f"  [error listing PRs] {info['prs_err']}")
        elif not info["prs"]:
            print("  Open renovate PRs: none")
        else:
            print(f"  Open renovate PRs ({len(info['prs'])}):")
            for pr in info["prs"]:
                stage = info["branch_to_stage"].get(pr["headRefName"], "not in Dependency Dashboard")
                state = rollups.get((repo, pr["number"]))
                build_status = STATUS_ROLLUP_LABEL.get(state, "No status checks")
                print(f"    #{pr['number']}: {pr['title']}")
                print(f"        stage: {stage} | build: {build_status}")

        if info["dashboard_err"] is not None:
            print(f"  [error reading Dependency Dashboard] {info['dashboard_err']}")
            continue

        remaining_counts = {
            stage: count
            for stage, count in info["counts"].items()
            if stage not in STAGES_SHOWN_VIA_PR_LIST
        }
        if not remaining_counts:
            print("  Dependency Dashboard: no other queued updates found")
        else:
            print(f"  Dependency Dashboard (#{info['issue']['number']}) queued updates by stage:")
            for stage, count in remaining_counts.items():
                print(f"    {stage}: {count}")


if __name__ == "__main__":
    sys.exit(main())
