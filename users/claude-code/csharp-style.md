---
paths:
  - "**/*.cs"
---

# C# style

- Prefer `"""` triple-quoted string literals over concatenating `"` strings with `"\n"`.
- When comparing strings/text that may contain line endings in tests, use `String.ReplaceLineEndings` so the test isn't dependent on the environment's line ending convention.
