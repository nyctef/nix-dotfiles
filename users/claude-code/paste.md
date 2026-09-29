---
name: paste
description: upload files to a personal pastebin. use when asked to produce reports, draft comments, or get files out of a sandbox easily
allowed-tools: Bash(curl)
---

## Step 0: make the file

- Default to markdown if creating a report, or when filling out an issue template
- Use code snippets liberally when referencing code, rather than just naming classes or line numbers
- Consider switching to html if more complex diagrams are required.

## Step 1: upload

upload the file:

```bash
curl -fLF "file=@report.md" https://paste.nyctef.com
```

this will give you a link:

```
https://paste.nyctef.com/f/123-AbC
```

## Step 2: hand it over

Provide a curl command for the user to run which saves the file to a specific location:

```
curl -fL -o foo-explanation-report.md https://paste.nyctef.com/f/123-AbC
curl -fL -o arch-overview.html https://paste.nyctef.com/f/456-dEf
```

