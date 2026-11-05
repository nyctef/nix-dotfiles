## Committing

- commit regularly to checkpoint changes. Commit early and often. More commits is usually better.
  - split refactorings out into their own commits: eg if extracting or moving a code and changing it at the same time, having the move in its own commit makes reviewing it much easier.
  - refactoring-only commits should be clearly marked with `refactor: `.
  - a commit must only be marked as `refactor: ` if it is a strict refactoring ("extract function", "inline variable", "rename field" etc). any actual changes to the logic are not refactorings
- do not add github issue references to commit messages

## General instructions

- use the gh cli to read contents of issues and pull requests. fetch both description and comments
- if on a detached HEAD then stay there. only create or switch branches when told to.
- when executing tests or other long-running commands, prefer to pipe the output to a temporary file and analyze it separately, instead of piping to grep or tail directly. This avoids having to re-run the command when more details are needed.
- if you find yourself reverse-engineering a dll to inspect its behavior, or webfetching individual pages on github.com to inspect source code, then prefer to grab a local clone of the repo instead and inspect the code that way. This applies to both public and private repos.
- be careful not to add BOMs to files. avoid 'utf-8-sig' for writes in scripts.

## When writing code comments or docs
- Avoid adding comments which just narrate the diff or refer to specific jargon within the agent session.
- Do include comments if the resulting state is strange or non-obvious.
- Add comments next to the relevant sections of code. Avoid describing the behavior of other components in a comment.
- Write comments and docs as if there was never a "before" — describe current behavior, not what changed or why it's now better/fixed/improved. If a sentence would only make sense to someone who just watched the diff happen, rewrite it as a plain statement of fact instead.
