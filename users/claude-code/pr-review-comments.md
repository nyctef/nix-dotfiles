---
name: pr-review-comments
description: Use when fetching review comments from a GitHub PR, listing code review feedback, or checking which PR comments are resolved vs open
allowed-tools: Bash(gh api graphql:*)
---

## Overview

Fetch all review comments from a GitHub pull request, including the comment text, associated code location, and resolved status. Uses the GraphQL API which provides resolved status that the REST API lacks.

## Quick Reference

**GraphQL query for review threads with resolved status:**

```bash
gh api graphql -f query='
{
  repository(owner: "OWNER", name: "REPO") {
    pullRequest(number: PR_NUMBER) {
      reviewThreads(first: 50) {
        nodes {
          isResolved
          comments(first: 1) {
            nodes {
              body
              path
              line
            }
          }
        }
      }
    }
  }
}'
```

## Implementation

### Step 1: Fetch review threads via GraphQL

use above `gh api` call, substituting values for OWNER REPO and PR_NUMBER

### Step 2: Parse and present results

Extract from JSON response:
- `isResolved` - boolean for resolved status
- `comments.nodes[0].body` - comment text
- `comments.nodes[0].path` - file path
- `comments.nodes[0].line` - line number (may be null for outdated comments)

### Output format

Present as a list:

```markdown
## Comment 1
file: path/to/file:1234
<comment text>

```

Skip listing resolved comments unless the user specifically asks for them

Include summary: "X comments total, Y resolved, Z open"

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Using REST API (`gh api repos/.../pulls/.../comments`) | REST API lacks `isResolved` field - use GraphQL |
| Using `gh pr view --json reviews` | Returns review objects, not individual comments |
| Forgetting `first: N` in GraphQL | Query fails without pagination limits |

## Notes

- `line` may be `null` if the code was changed since the comment was made
- For full diff context, the REST API (`gh api repos/.../pulls/.../comments`) includes `diff_hunk`
- Increase `first: 50` if PR has more than 50 review threads
