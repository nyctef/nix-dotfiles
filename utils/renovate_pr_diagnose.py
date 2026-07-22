#!/usr/bin/env python3
"""
Diagnose why a single renovate PR is blocked: summarize its diff and dig into
any failing status checks (GitHub Actions job/step/annotations, or TeamCity
build problems/failed tests) so there's enough detail to unblock it without
having to click through to each CI system by hand.

Usage: renovate_pr_diagnose.py <owner/repo> <pr-number>
"""

import json
import subprocess
import sys
from datetime import datetime, timedelta
from urllib.parse import urlparse

DIFF_LINE_LIMIT = 200
TEST_FAILURE_LIMIT = 5
TEST_DETAILS_CHAR_LIMIT = 1500
LOG_SNIPPET_LINE_LIMIT = 80


def run_gh(args, input=None):
    result = subprocess.run(["gh", *args], input=input, capture_output=True, text=True)
    if result.returncode != 0:
        return None, result.stderr.strip()
    return result.stdout, None


def run_gh_json(args):
    out, err = run_gh(args)
    if err is not None:
        return None, err
    return json.loads(out), None


def curl_json(url):
    result = subprocess.run(
        ["curl", "-s", "-H", "Accept: application/json", url],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        return None, f"curl failed: {result.stderr.strip()}"
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError:
        return None, f"non-JSON response: {result.stdout[:200]}"


def print_pr_summary(repo, pr_number):
    pr, err = run_gh_json([
        "pr", "view", str(pr_number), "--repo", repo,
        "--json", "title,baseRefName,headRefName,additions,deletions,files,url",
    ])
    if err is not None:
        print(f"[error] could not fetch PR: {err}")
        return

    print(f"PR #{pr_number}: {pr['title']}")
    print(f"  {pr['url']}")
    print(f"  {pr['headRefName']} -> {pr['baseRefName']}  (+{pr['additions']}/-{pr['deletions']})")
    print("  Files changed:")
    for f in pr["files"]:
        print(f"    {f['changeType']:10s} +{f['additions']}/-{f['deletions']}  {f['path']}")

    diff, err = run_gh(["pr", "diff", str(pr_number), "--repo", repo])
    if err is not None:
        print(f"  [error fetching diff] {err}")
        return
    diff_lines = diff.splitlines()
    print("\n  Diff:")
    for line in diff_lines[:DIFF_LINE_LIMIT]:
        print(f"    {line}")
    if len(diff_lines) > DIFF_LINE_LIMIT:
        print(f"    ... ({len(diff_lines) - DIFF_LINE_LIMIT} more lines omitted)")


def parse_gha_timestamp(ts):
    # GHA log/API timestamps look like "2026-07-20T10:15:23.1234567Z" - trim to
    # microsecond precision so datetime.fromisoformat can parse them.
    ts = ts.rstrip("Z")
    if "." in ts:
        head, frac = ts.split(".", 1)
        ts = f"{head}.{frac[:6]}"
    try:
        return datetime.fromisoformat(ts)
    except ValueError:
        return None


def extract_step_log_lines(log_text, step_started_at, step_completed_at):
    """The per-job log endpoint returns one combined, timestamp-prefixed log for
    every step. There's no per-step boundary marker, so slice by matching each
    line's leading timestamp against the step's started_at/completed_at window.

    step_completed_at is whole-second precision, but log lines carry
    sub-second timestamps - a step's own closing log lines (often the most
    informative, e.g. the actual ##[error] line) can land later within that
    same second and get excluded. Pad the end boundary by a second to avoid
    truncating them."""
    start = parse_gha_timestamp(step_started_at) if step_started_at else None
    end = parse_gha_timestamp(step_completed_at) if step_completed_at else None
    if end is not None:
        end += timedelta(seconds=1)
    lines = []
    for line in log_text.splitlines():
        ts_str, sep, text = line.partition(" ")
        if not sep:
            continue
        ts = parse_gha_timestamp(ts_str)
        if ts is None:
            continue
        if start and ts < start:
            continue
        if end and ts > end:
            continue
        lines.append(text)
    return lines


def diagnose_github_actions_check(repo, link):
    # link looks like https://github.com/<owner>/<repo>/actions/runs/<run_id>/job/<job_id>
    job_id = urlparse(link).path.rstrip("/").split("/")[-1]

    job, err = run_gh_json(["api", f"repos/{repo}/actions/jobs/{job_id}"])
    if err is not None:
        print(f"    [error fetching job] {err}")
        return

    failed_steps = [s for s in job.get("steps", []) if s.get("conclusion") == "failure"]
    print(f"    job: {job['name']} ({job['conclusion']})")
    for step in failed_steps:
        print(f"    failed step: {step['number']}. {step['name']}")

    log_text, log_err = run_gh(["api", f"repos/{repo}/actions/jobs/{job_id}/logs"])
    if log_err is not None:
        print(f"    [error fetching log] {log_err}")
        return

    for step in failed_steps:
        lines = extract_step_log_lines(log_text, step.get("started_at"), step.get("completed_at"))
        print(f"\n    log snippet for step {step['number']}. {step['name']}:")
        if not lines:
            print("      (no log lines matched this step's time window)")
            continue
        snippet = lines[-LOG_SNIPPET_LINE_LIMIT:]
        if len(lines) > len(snippet):
            print(f"      ... ({len(lines) - len(snippet)} earlier lines omitted)")
        for line in snippet:
            print(f"      {line}")


def diagnose_teamcity_check(link):
    # link looks like https://buildserver.red-gate.com/buildConfiguration/<config>/<build_id>
    build_id = urlparse(link).path.rstrip("/").split("/")[-1]
    base = f"{urlparse(link).scheme}://{urlparse(link).netloc}"

    build, err = curl_json(
        f"{base}/app/rest/builds/id:{build_id}"
        "?fields=id,number,status,statusText,state,webUrl,"
        "problemOccurrences(problemOccurrence(type,details))"
    )
    if err is not None:
        print(f"    [error fetching TeamCity build] {err}")
        return

    print(f"    build #{build.get('number')}: {build.get('statusText')}")
    problems = build.get("problemOccurrences", {}).get("problemOccurrence", [])
    has_failed_tests = False
    for problem in problems:
        print(f"    problem [{problem['type']}]: {problem['details']}")
        if problem["type"] == "TC_FAILED_TESTS":
            has_failed_tests = True

    if not has_failed_tests:
        return

    tests, err = curl_json(
        f"{base}/app/rest/testOccurrences"
        "?locator=build:(id:{}),status:FAILURE&fields=testOccurrence(name,details)".format(build_id)
    )
    if err is not None:
        print(f"    [error fetching failed tests] {err}")
        return

    # Failures sharing the same setup/assertion error (e.g. a flaky shared
    # fixture) are common and repeating the full detail per-test is just noise.
    names_by_details = {}
    for test in tests.get("testOccurrence", []):
        names_by_details.setdefault(test.get("details", ""), []).append(test["name"])

    for details, names in list(names_by_details.items())[:TEST_FAILURE_LIMIT]:
        if len(details) > TEST_DETAILS_CHAR_LIMIT:
            details = details[:TEST_DETAILS_CHAR_LIMIT] + "... (truncated)"
        if len(names) > 1:
            print(f"    failed tests ({len(names)}, identical error):")
            for name in names:
                print(f"      - {name}")
        else:
            print(f"    failed test: {names[0]}")
        for line in details.splitlines():
            print(f"      {line}")

    if len(names_by_details) > TEST_FAILURE_LIMIT:
        print(f"    ... ({len(names_by_details) - TEST_FAILURE_LIMIT} more distinct failures omitted)")


def print_check_diagnosis(repo, checks):
    failing = [c for c in checks if c["bucket"] == "fail"]
    if not failing:
        print("\nNo failing checks.")
        return

    print(f"\n{len(failing)} failing check(s):")
    for check in failing:
        print(f"\n  {check['workflow']} / {check['name']}")
        print(f"    {check['link']}")
        host = urlparse(check["link"]).netloc
        if host == "github.com":
            diagnose_github_actions_check(repo, check["link"])
        elif host == "buildserver.red-gate.com":
            diagnose_teamcity_check(check["link"])
        else:
            print(f"    (unrecognized check host {host!r}; no further detail available)")


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <owner/repo> <pr-number>", file=sys.stderr)
        return 1
    repo, pr_number = sys.argv[1], sys.argv[2]

    print_pr_summary(repo, pr_number)

    checks, err = run_gh_json([
        "pr", "checks", str(pr_number), "--repo", repo,
        "--json", "name,workflow,bucket,state,link,description",
    ])
    if err is not None:
        print(f"\n[error fetching checks] {err}")
        return 1

    print_check_diagnosis(repo, checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
