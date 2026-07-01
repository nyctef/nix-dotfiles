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

# ---------- pi-specific bind mounts ----------
# The container user is still 'claude' (generalising is deferred per README).

PI_CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"

MOUNTS=(
    # Mount the entire /nix/store so pi's full closure (node, fd, ripgrep, etc.)
    # is available. This is a zero-copy bind mount.
    --mount "ro:/nix/store:/nix/store"
    # Pi config and state — rw because pi writes sessions, settings.
    --mount "rw:${PI_CONFIG_DIR}:/home/claude/.pi/agent"
    # Host dotfiles (for AGENTS.md, project instructions, etc.)
    --mount "ro:${HOME}/.dotfiles:/home/claude/.dotfiles"
    # Git config (needed for commits, gh CLI, etc.)
    --mount "ro:${HOME}/.gitconfig:/home/claude/.gitconfig"
    --mount "ro:${HOME}/.config/git/:/home/claude/.config/git/"
    # GitHub CLI config (gh pr, gh issue, etc.)
    --mount "ro:${HOME}/.config/gh:/home/claude/.config/gh"
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
)

# Pass through the API key if set on the host (pi reads ANTHROPIC_API_KEY or
# its own auth.json; the env var takes precedence).
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    ENVS+=( --env "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" )
fi

# Pass through any other provider keys that might be configured.
for var in OPENAI_API_KEY GOOGLE_API_KEY OPENROUTER_API_KEY; do
    if [[ -n "${!var:-}" ]]; then
        ENVS+=( --env "${var}=${!var}" )
    fi
done

# ---------- hand off to the generic core ----------

"$HERE/run-agent-sandbox.sh" \
    --agent-cmd "${PI_DRV}/bin/pi" \
    "${MOUNTS[@]}" \
    "${ENVS[@]}" \
    ${WORKTREE_ARGS[@]+"${WORKTREE_ARGS[@]}"} \
    -- ${PI_ARGS[@]+"${PI_ARGS[@]}"}
