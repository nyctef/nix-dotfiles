---
name: reverse-engineer-claude-binary
description: Use when answering questions about Claude Code internals, settings merge behavior, sandbox implementation, permission resolution, or any "how does Claude Code work under the hood" question that documentation doesn't cover
---

# Reverse Engineering the Claude Code Binary

## Overview

The Claude Code native binary is a Bun-compiled single-file executable containing minified JavaScript. Readable strings (function names, object keys, string literals) survive compilation and can be extracted to answer questions about internal behavior.

## When to Use

- User asks how Claude Code settings are merged, resolved, or prioritized
- User asks about sandbox internals, seccomp, permission checks
- User asks about any undocumented Claude Code behavior
- Documentation is ambiguous and source-level confirmation is needed
- NOT needed for questions answerable from official docs

## Quick Reference

### Locate the Binary

```bash
# Follow symlink to actual versioned binary
ls -la $(which claude)
# e.g. ~/.local/share/claude/versions/2.1.42
```

### Find String Offsets

```bash
# Count occurrences (verify target exists)
grep -ac 'targetString' /path/to/claude

# Get byte offsets for all occurrences
grep -aob 'targetString' /path/to/claude
```

### Extract Readable Code Around an Offset

**Use perl** (python/node may not be available in sandboxed environments):

```bash
perl -e '
open(my $fh, "<:raw", "/path/to/claude") or die;
seek($fh, OFFSET - 200, 0);
read($fh, my $buf, 2000);
$buf =~ s/[^\x20-\x7E]/\x01/g;
my @parts = split /\x01+/, $buf;
print join("\n", grep { length($_) > 2 } @parts), "\n";
close($fh);
'
```

Adjust the seek offset (start earlier/later) and read length as needed. The extracted text is minified JS - variable names are mangled but string literals, object keys, and function structure are intact.

## Core Technique

1. **Identify search terms** - Use meaningful strings: setting names (`excludedCommands`), function names (`getExcludedCommands`), error messages, or config keys
2. **Get offsets** - `grep -aob` finds byte positions of every occurrence
3. **Extract context** - Read ~2KB around each offset with perl, filtering to printable ASCII
4. **Read minified JS** - The output is valid JS with mangled variable names. String literals, property accesses, and control flow are readable
5. **Cross-reference offsets** - The binary contains duplicate copies (likely code + sourcemap). If one offset gives poor context, try another

## Common Search Targets

| Question | Search Terms |
|----------|-------------|
| Settings merge | `excludedCommands`, `userSettings`, `projectSettings`, `localSettings`, `policySettings` |
| Sandbox config | `excludedCommands`, `autoAllowBashIfSandboxed`, `allowUnsandboxedCommands`, `enabledPlatforms` |
| Permission resolution | `allow`, `deny`, `ask`, `defaultMode`, `permissions` |
| Settings sources | `userSettings`, `projectSettings`, `localSettings`, `flagSettings`, `policySettings` |
| Merge behavior | Look for `Array.from(new Set(`, `...spread`, `.concat(` near setting names |

## Common Mistakes

- **Using `strings` command** - Often not installed in NixOS/sandbox environments. Use `grep -ac` to verify and `perl` to extract
- **Using `grep -P` with binary** - Extended perl regex on binary files can produce empty output. Use `-aob` for offsets, then perl for context
- **Reading wrong copy** - Binary contains duplicate code sections. If one offset gives unrelated context (e.g. protobuf, rxjs), try the next offset
- **Trusting mangled names** - Variable names like `H`, `$`, `NL` are meaningless. Follow the logic through string literals and property accesses instead
