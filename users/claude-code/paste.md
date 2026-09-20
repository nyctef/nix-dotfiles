---
name: paste
description: upload files to a personal pastebin. use when asked to produce reports, draft comments, or get files out of a sandbox easily
allowed-tools: Bash(curl)
---

upload the file:

```bash
curl -fLF "file=@report.md" https://paste.nyctef.com
```

this will give you a link:

```
https://paste.nyctef.com/f/123-AbC
```

## Step 2: hand it over

Either report the link directly, or (optionally) provide a curl command
for the user to run which saves the file to a specific location:

```
curl -fL -o report.md --output-dir /path/to/reports https://paste.nyctef.com/f/123-AbC
```

