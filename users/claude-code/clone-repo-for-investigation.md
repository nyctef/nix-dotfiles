---
name: clone-repo-for-investigation
description: Use when investigating third-party source code, tracing bugs in dependencies, reading upstream library internals, or needing to search across a repository not already cloned locally
allowed-tools: Bash(gh repo clone:*), Bash(git clone:*)
---

## Overview

Clone third-party repos locally for efficient investigation instead of making repeated WebFetch/GitHub API calls. Local clones enable Grep, Glob, and Read tools which are faster and more reliable than fetching individual files via HTTP.

## When to Use

- Investigating a bug in a dependency (e.g., NUnit adapter, EF Core)
- Tracing code paths across multiple files in an upstream library
- Searching for patterns, usages, or implementations in third-party code
- Any time you'd otherwise make 3+ WebFetch calls to the same repo

## Quick Reference

```bash
# Clone to sandbox-writable temp directory
gh repo clone owner/repo /tmp/claude/repos/repo

# Shallow clone for large repos (faster, less disk)
gh repo clone owner/repo /tmp/claude/repos/repo -- --depth 1

# Clone a specific branch or tag
gh repo clone owner/repo /tmp/claude/repos/repo -- --branch v4.5.0 --depth 1
```

## Implementation

### Step 1: Clone into `/tmp/claude/repos/`

```bash
gh repo clone owner/repo /tmp/claude/repos/repo
```

Use `/tmp/claude/repos/` as the base directory — it's writable in the sandbox and clearly separated from the user's own code.

### Step 2: Investigate using standard tools

Once cloned, use Grep, Glob, and Read on the local checkout:

```bash
# Find relevant files
Glob: /tmp/claude/repos/repo/**/DiscoveryConverter.cs

# Search for patterns
Grep: "ExplicitMode" in /tmp/claude/repos/repo/

# Read specific files
Read: /tmp/claude/repos/repo/src/SomeFile.cs
```

### Step 3: Clean up (optional)

Clones in `/tmp/claude/` are ephemeral and cleaned up automatically. No action needed.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Using WebFetch to read individual GitHub files | Clone the repo and use local tools |
| Cloning into the user's project directory | Always use `/tmp/claude/repos/` |
| Full clone of a huge repo when only reading | Use `--depth 1` for shallow clone |
| Forgetting `gh` auth — using raw `git clone` for private repos | `gh repo clone` handles auth automatically |
