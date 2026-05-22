#!/usr/bin/env python3
"""Pick a recent Claude Code session/subagent log and dump its tail."""

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

PROJECTS = Path.home() / ".claude" / "projects"
LIST_LIMIT = 50
TAIL_ENTRIES = 50
TOOL_RESULT_MAX = 400


def gather_files():
    out = []
    for p in PROJECTS.rglob("*.jsonl"):
        try:
            out.append((p.stat().st_mtime, p))
        except OSError:
            pass
    out.sort(reverse=True)
    return out[:LIST_LIMIT]


def load_index(project_dir):
    idx = project_dir / "sessions-index.json"
    if not idx.exists():
        return {}
    try:
        data = json.loads(idx.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return {e["sessionId"]: e for e in data.get("entries", []) if "sessionId" in e}


def short(s, n=70):
    s = (s or "").replace("\n", " ").strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def scan_file_meta(path):
    """Return dict with slug, agentId, firstPrompt by scanning the jsonl."""
    meta = {}
    try:
        with path.open() as f:
            for line in f:
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "slug" not in meta and obj.get("slug"):
                    meta["slug"] = obj["slug"]
                    meta["agentId"] = obj.get("agentId")
                if "firstPrompt" not in meta and obj.get("type") == "user":
                    c = obj.get("message", {}).get("content")
                    if isinstance(c, str) and c.strip():
                        meta["firstPrompt"] = c
                    elif isinstance(c, list):
                        for item in c:
                            if isinstance(item, dict) and item.get("type") == "text":
                                meta["firstPrompt"] = item.get("text", "")
                                break
                if "firstPrompt" in meta and ("slug" in meta or not _is_subagent_path(path)):
                    break
    except OSError:
        pass
    return meta


def _is_subagent_path(path):
    parts = path.relative_to(PROJECTS).parts
    return len(parts) >= 3 and parts[-2] == "subagents"


def display_name(path, index_cache):
    rel = path.relative_to(PROJECTS)
    parts = rel.parts
    project_dir_name = parts[0]
    project_dir = PROJECTS / project_dir_name

    if project_dir_name not in index_cache:
        index_cache[project_dir_name] = load_index(project_dir)
    index = index_cache[project_dir_name]

    is_subagent = len(parts) >= 3 and parts[-2] == "subagents"
    session_id = parts[1] if is_subagent else path.stem

    entry = index.get(session_id, {})
    project_path = entry.get("projectPath")
    proj_short = Path(project_path).name if project_path else project_dir_name

    summary = entry.get("summary") or entry.get("firstPrompt")
    file_meta = None
    if not summary or is_subagent:
        file_meta = scan_file_meta(path)
    if not summary:
        summary = (file_meta or {}).get("firstPrompt") or "(no summary)"

    mtime = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M")

    if is_subagent:
        slug = (file_meta or {}).get("slug")
        tag = slug or path.stem
        return f"{mtime}  {proj_short}: {short(summary)}  ↳ {tag}"
    return f"{mtime}  {proj_short}: {short(summary)}"


def render_content(content, verbose=False):
    if isinstance(content, str):
        return content if verbose else ""
    if not isinstance(content, list):
        return str(content)
    out = []
    for item in content:
        if not isinstance(item, dict):
            continue
        it = item.get("type")
        if it == "text":
            out.append(item.get("text", ""))
        elif it == "thinking":
            out.append(f"[thinking]\n{item.get('thinking', '')}")
        elif it == "tool_use":
            if not verbose:
                continue
            name = item.get("name")
            inp = item.get("input", {})
            inp_str = json.dumps(inp, ensure_ascii=False)
            if len(inp_str) > TOOL_RESULT_MAX:
                inp_str = inp_str[:TOOL_RESULT_MAX] + "…"
            out.append(f"[tool_use: {name}] {inp_str}")
        elif it == "tool_result":
            if not verbose:
                continue
            c = item.get("content", "")
            if isinstance(c, list):
                c = "".join(
                    sub.get("text", "") if isinstance(sub, dict) else str(sub)
                    for sub in c
                )
            c = str(c)
            if len(c) > TOOL_RESULT_MAX:
                c = c[:TOOL_RESULT_MAX] + "…"
            err = " (error)" if item.get("is_error") else ""
            out.append(f"[tool_result{err}] {c}")
        elif it == "image":
            if verbose:
                out.append("[image]")
    return "\n".join(p for p in out if p)


def render_entry(obj, verbose=False):
    t = obj.get("type")
    if t == "user":
        if not verbose:
            return None
        content = obj.get("message", {}).get("content")
        body = render_content(content, verbose=True)
        if not body.strip():
            return None
        return f"── user ──\n{body}"
    if t == "assistant":
        content = obj.get("message", {}).get("content", [])
        body = render_content(content, verbose=verbose)
        if not body.strip():
            return None
        return f"── assistant ──\n{body}"
    return None


def render_tail(path, n=TAIL_ENTRIES, verbose=False, full=False):
    rendered = []
    try:
        text = path.read_text(errors="replace")
    except OSError as e:
        return f"(failed to read {path}: {e})"
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        r = render_entry(obj, verbose=verbose)
        if r:
            rendered.append(r)
    if full:
        return "\n\n".join(rendered) if rendered else "(no renderable entries)"
    tail = rendered[-n:]
    tail.reverse()
    return "\n\n".join(tail) if tail else "(no renderable entries)"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="include user messages, tool_use, and tool_result (default: assistant text + thinking only)",
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help=f"dump entire session log oldest-first (default: last {TAIL_ENTRIES} entries, newest-first)",
    )
    args = parser.parse_args()

    if not PROJECTS.exists():
        print(f"no claude projects dir at {PROJECTS}", file=sys.stderr)
        sys.exit(1)

    files = gather_files()
    if not files:
        print("no session files found", file=sys.stderr)
        sys.exit(1)

    index_cache = {}
    rows = []
    for _, path in files:
        try:
            label = display_name(path, index_cache)
        except Exception as e:
            label = f"(error: {e})"
        rows.append(f"{path}\t{label}")

    result = subprocess.run(
        ["fzf", "--with-nth=2..", "--delimiter=\t", "--no-sort", "--height=40%", "--reverse"],
        input="\n".join(rows),
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        sys.exit(result.returncode)
    line = result.stdout.strip()
    if not line:
        sys.exit(1)
    selected = Path(line.split("\t", 1)[0])

    output = f"# {selected}\n\n{render_tail(selected, verbose=args.verbose, full=args.full)}\n"
    pager = subprocess.run(["less", "-FRX"], input=output, text=True)
    sys.exit(pager.returncode)


if __name__ == "__main__":
    main()
