---
name: renovate-triage
description: Help with managing the renovate backlog
disable-model-invocation: true
allowed-tools: Bash(renovate-dashboard:*), Bash(renovate-pr-diagnose:*), Bash(gh repo clone:*)
---

## Overview

Triages renovate-managed dependency-update PRs: summarizes open PRs and
Dependency Dashboard queue state, flags PRs that are green and ready to merge,
and digs into failing PRs' diffs/CI output to suggest a likely cause and next
step.

**This skill is investigate-only.** It must never merge a PR, push a commit,
close/edit a PR, or otherwise modify a repository. Every output is a report and
a suggestion for a human to act on.

## Tools available

- `renovate-dashboard` — lists open renovate PRs plus each one's Dependency
  Dashboard stage and build status (Building / Build succeeded / Build failed),
  across the fixed repo list defined inside `utils/renovate_dashboard.py` (edit
  `REPOS` there to change coverage). Also reports dashboard-only stage counts
  (Rate-Limited, Pending Status Checks, Ignored/Blocked, ...) not already
  covered by the PR list.
- `renovate-pr-diagnose <owner/repo> <pr-number>` — diff summary plus
  failing-check detail for one PR: GitHub Actions job/step/raw log snippet, or
  TeamCity build problems and deduped failed-test detail.

## Workflow

### Step 1: Run the dashboard

Run `renovate-dashboard` and present the results to the user as-is: open PRs
(with stage + build status), and any remaining dashboard stage counts.

### Step 2: Flag ready-to-merge PRs

Any open PR with build status "Build succeeded" is a merge candidate,
regardless of its Dependency Dashboard stage (e.g. a PR staged "Edited/Blocked"
because someone pushed a manual commit is still a real open PR — if it's green,
it's still worth flagging). Call these out explicitly by repo and PR number. Do
not merge them yourself — just suggest it.

### Step 3: Diagnose failing PRs

Take a look at one PR with build status "Build failed", run
`renovate-pr-diagnose <owner/repo> <pr-number>` and read the diff plus failure
detail.

If the diff/log doesn't give enough context (e.g. need to see surrounding code,
or check whether a warning pre-dates this PR), shallow-clone the repo's PR
branch to a temp location and investigate there:

```bash
gh repo clone <owner/repo> /tmp/claude/repos/<repo> -- --branch <headRefName> --depth 1
```

Then use Grep/Glob/Read against that checkout. No cleanup needed —
`/tmp/claude/repos/` is ephemeral.

For this failing PR, summarize the likely root cause (e.g. "breaking API change
in the new major version", "unrelated TeamCity docker-agent flake", "SDK bump
promoted a pre-existing nullable warning to an error") and a concrete suggested
next step (fix a specific line, bump a related package alongside it,
rebase/retry since it's an infra flake, or close/ignore if not worth pursuing).

### Step 4: Report

Summarize per repo: how many PRs are ready to merge, how many are failing
(1-line cause + suggestion each), how many are still building/pending, and how
many are queued at other dashboard stages.

## Constraints

This skill is used only for reporting current status and suggesting potential
unblocking actions. Mutations/fixes will either be given as explicit instructions
or followed up in a subsequent session.

