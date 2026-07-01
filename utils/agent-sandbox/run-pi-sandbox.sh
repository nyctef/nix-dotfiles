#!/usr/bin/env bash
set -euo pipefail

# Pi-specific wrapper around run-agent-sandbox.sh.
#
# Supplies everything that makes a run pi-specific — the agent command, the pi
# binary (a Nix closure), its config/state mounts, and its env — then hands off
# to the generic core. Mirrors run-claude-sandbox.sh for Claude.
#
# Unlike the Claude binary (a single ELF), pi is a Nix-wrapped Node.js app
# whose bash shims contain hard-coded /nix/store/ paths (node, fd, ripgrep,
# etc.). We mount the entire /nix/store read-only so the full closure is
# available inside the container. This is a zero-copy bind mount.
#
# Usage: run-pi-sandbox.sh [--worktree <name>] [pi args...]
#   Run from any project directory — it mounts $PWD as the working dir.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- split our args: --worktree is for the core, the rest are pi's ----------

WORKTREE_ARGS=()
PI_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --worktree) WORKTREE_ARGS=(--worktree "$2"); shift 2 ;;
        *)          PI_ARGS+=("$1"); shift ;;
    esac
done

# ---------- pi binary ----------

PI_BINARY="$(command -v pi 2>/dev/null)" || true
if [[ -z "$PI_BINARY" ]]; then
    echo "ERROR: pi not found in PATH" >&2
    exit 1
fi

# Resolve the final store path (pi -> .pi-wrapped -> nix store).
PI_STORE_PATH="$(readlink -f "$PI_BINARY")"
# Walk up to the store derivation root (e.g. /nix/store/xxx-pi-coding-agent-0.79.1).
PI_DRV="$(echo "$PI_STORE_PATH" | sed 's|\(/nix/store/[^/]*\)/.*|\1|')"

if [[ ! -d "$PI_DRV" ]]; then
    echo "ERROR: could not determine pi's Nix store derivation from $PI_BINARY" >&2
    exit 1
fi

# ---------- Phase C: generate placeholder configs for credential injection ----------

PHASE_C_TMPDIR="$(mktemp -d)"

# GitHub CLI: synthetic hosts.yml with the placeholder token.
mkdir -p "$PHASE_C_TMPDIR/gh"
cat > "$PHASE_C_TMPDIR/gh/hosts.yml" <<'GHEOF'
github.com:
    oauth_token: SANDBOX-PLACEHOLDER-GH-TOKEN
    user: sandbox-agent
    git_protocol: https
GHEOF

# Git credential helper: returns placeholder tokens for the proxy to swap.
cat > "$PHASE_C_TMPDIR/git-credential-sandbox.sh" <<'GCEOF'
#!/bin/sh
host=""
while IFS='=' read -r key value; do
    [ "$key" = "host" ] && host="$value"
done
case "$host" in
    github.com|*.github.com)
        echo "protocol=https"
        echo "host=$host"
        echo "username=x-access-token"
        echo "password=SANDBOX-PLACEHOLDER-GH-TOKEN"
        ;;
esac
GCEOF
chmod +x "$PHASE_C_TMPDIR/git-credential-sandbox.sh"

mkdir -p "$PHASE_C_TMPDIR/gitconfig.d"
cat > "$PHASE_C_TMPDIR/gitconfig.d/sandbox-credentials.inc" <<'GITEOF'
[credential]
    helper = /opt/sandbox/git-credential-sandbox.sh
GITEOF

# Sanitize the host gitconfig: copy it but strip credential helper sections.
if [[ -f "${HOME}/.gitconfig" ]]; then
    python3 -c "
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(
    r'\[credential[^\]]*\]\n(?:[ \t]+[^\n]*\n)*',
    '',
    text
)
open(sys.argv[2], 'w').write(text)
" "${HOME}/.gitconfig" "$PHASE_C_TMPDIR/gitconfig-sanitized"
else
    touch "$PHASE_C_TMPDIR/gitconfig-sanitized"
fi

# Sanitize ~/.config/git/config similarly.
mkdir -p "$PHASE_C_TMPDIR/config-git"
if [[ -f "${HOME}/.config/git/config" ]]; then
    python3 -c "
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(
    r'\[credential[^\]]*\]\n(?:[ \t]+[^\n]*\n)*',
    '',
    text
)
open(sys.argv[2], 'w').write(text)
" "${HOME}/.config/git/config" "$PHASE_C_TMPDIR/config-git/config"
else
    touch "$PHASE_C_TMPDIR/config-git/config"
fi
for f in "${HOME}/.config/git/"*; do
    fname="$(basename "$f")"
    [[ "$fname" == "config" ]] && continue
    if [[ ! -e "$PHASE_C_TMPDIR/config-git/$fname" ]]; then
        cp -a "$f" "$PHASE_C_TMPDIR/config-git/$fname" 2>/dev/null || true
    fi
done

# Sanitize pi config: copy settings.json and auth.json with real API keys
# replaced by placeholders. Pi needs these files to start, but the real keys
# go through the sidecar proxy.
PI_CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
mkdir -p "$PHASE_C_TMPDIR/pi-config"

# Extract pi's Anthropic API key from auth.json and export it so the core
# launcher (run-agent-sandbox.sh) can pass it to the sidecar proxy. Pi stores
# its own API key here (separate billing from Claude Code's OAuth subscription).
# The env var is only used by the core's sidecar credential resolution — the
# agent container gets the placeholder, not the real key.
if [[ -z "${ANTHROPIC_API_KEY:-}" && -f "$PI_CONFIG_DIR/auth.json" ]]; then
    _PI_API_KEY="$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    key = data.get('anthropic', {}).get('key', '')
    if key and not key.startswith('SANDBOX-PLACEHOLDER'):
        print(key)
except Exception:
    pass
" "$PI_CONFIG_DIR/auth.json" 2>/dev/null)" || true
    if [[ -n "${_PI_API_KEY:-}" ]]; then
        export ANTHROPIC_API_KEY="$_PI_API_KEY"
    fi
    unset _PI_API_KEY
fi

# Copy the full pi config dir structure (sessions, etc.) but sanitize auth files.
if [[ -d "$PI_CONFIG_DIR" ]]; then
    # settings.json / auth.json: replace real API keys with placeholders.
    for authfile in settings.json auth.json; do
        if [[ -f "$PI_CONFIG_DIR/$authfile" ]]; then
            # Replace any sk-ant-* key with the placeholder.
            sed 's/sk-ant-[A-Za-z0-9_-]*/SANDBOX-PLACEHOLDER-ANTHROPIC-KEY/g' \
                "$PI_CONFIG_DIR/$authfile" > "$PHASE_C_TMPDIR/pi-config/$authfile"
        fi
    done
fi

cleanup_pi() { rm -rf "$PHASE_C_TMPDIR"; }
trap cleanup_pi EXIT

# ---------- pi-specific bind mounts ----------
# The container user is still 'claude' (generalising is deferred per README).

MOUNTS=(
    # Mount the entire /nix/store so pi's full closure (node, fd, ripgrep, etc.)
    # is available. This is a zero-copy bind mount.
    --mount "ro:/nix/store:/nix/store"
    # Pi config and state — rw because pi writes sessions, settings.
    # The directory itself is mounted rw (pi writes sessions), but auth files
    # are masked with sanitized copies containing placeholder keys.
    --mount "rw:${PI_CONFIG_DIR}:/home/claude/.pi/agent"
    # Phase C: mask auth files with sanitized copies (placeholder keys).
    --mount "ro:$PHASE_C_TMPDIR/pi-config/settings.json:/home/claude/.pi/agent/settings.json"
    --mount "ro:$PHASE_C_TMPDIR/pi-config/auth.json:/home/claude/.pi/agent/auth.json"
    # Host dotfiles (for AGENTS.md, project instructions, etc.)
    --mount "ro:${HOME}/.dotfiles:/home/claude/.dotfiles"
    # Phase C: sanitized gitconfig — credential helper sections stripped.
    --mount "ro:$PHASE_C_TMPDIR/gitconfig-sanitized:/home/claude/.gitconfig"
    --mount "ro:$PHASE_C_TMPDIR/config-git:/home/claude/.config/git"
    # Phase C: synthetic gh config with placeholder token (not real creds).
    --mount "ro:$PHASE_C_TMPDIR/gh:/home/claude/.config/gh"
    # Phase C: sandbox credential helper + git config overlay.
    --mount "ro:$PHASE_C_TMPDIR/git-credential-sandbox.sh:/opt/sandbox/git-credential-sandbox.sh"
    --mount "ro:$PHASE_C_TMPDIR/gitconfig.d/sandbox-credentials.inc:/opt/sandbox/sandbox-credentials.inc"
)

# .dotfiles must also resolve at its host absolute path inside the container
# (for hardcoded host paths in hooks/scripts).
if [[ "${HOME}/.dotfiles" != "/home/claude/.dotfiles" ]]; then
    MOUNTS+=( --mount "ro:${HOME}/.dotfiles:${HOME}/.dotfiles" )
fi

# ---------- pi-specific env ----------

ENVS=(
    # Point pi at its config dir inside the container.
    --env "PI_CODING_AGENT_DIR=/home/claude/.pi/agent"
    # Node.js OOM guard (same as Claude wrapper — pi is also Node.js).
    --env "NODE_OPTIONS=--max-old-space-size=4096"
    # Phase C: placeholder API keys. Real keys are in the sidecar proxy.
    --env "ANTHROPIC_API_KEY=SANDBOX-PLACEHOLDER-ANTHROPIC-KEY"
    # Phase C: git config include for the sandbox credential helper.
    --env "GIT_CONFIG_COUNT=1"
    --env "GIT_CONFIG_KEY_0=include.path"
    --env "GIT_CONFIG_VALUE_0=/opt/sandbox/sandbox-credentials.inc"
)

# Phase C: provider keys are injected via the sidecar proxy, not passed to
# the agent. For providers not yet in the credential map, we still pass
# placeholder values so the agent's SDK doesn't refuse to start.
for var in OPENAI_API_KEY GOOGLE_API_KEY OPENROUTER_API_KEY; do
    if [[ -n "${!var:-}" ]]; then
        ENVS+=( --env "${var}=SANDBOX-PLACEHOLDER-${var}" )
    fi
done

# ---------- hand off to the generic core ----------

"$HERE/run-agent-sandbox.sh" \
    --agent-cmd "${PI_DRV}/bin/pi" \
    "${MOUNTS[@]}" \
    "${ENVS[@]}" \
    ${WORKTREE_ARGS[@]+"${WORKTREE_ARGS[@]}"} \
    -- ${PI_ARGS[@]+"${PI_ARGS[@]}"}
