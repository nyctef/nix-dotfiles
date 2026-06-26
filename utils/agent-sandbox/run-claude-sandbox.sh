#!/usr/bin/env bash
set -euo pipefail

# Claude-specific wrapper around run-agent-sandbox.sh.
#
# Supplies everything that makes a run Claude-specific — the agent command, the
# `claude` binary, its config/credential mounts, and its env — then hands off to
# the generic core. A sibling wrapper (e.g. run-pi-sandbox.sh) would do the same
# for another agent without touching the core.
#
# Usage: run-claude-sandbox.sh [--worktree <name>] [claude args...]
#   Run from any project directory — it mounts $PWD as the working dir.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- split our args: --worktree is for the core, the rest are claude's ----------

WORKTREE_ARGS=()
CLAUDE_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --worktree) WORKTREE_ARGS=(--worktree "$2"); shift 2 ;;
        *)          CLAUDE_ARGS+=("$1"); shift ;;
    esac
done

# ---------- claude binary ----------

CLAUDE_BINARY="$(readlink -f ~/.local/bin/claude)"
if [[ ! -x "$CLAUDE_BINARY" ]]; then
    echo "ERROR: claude binary not found at $CLAUDE_BINARY" >&2
    exit 1
fi

# ---------- claude-specific bind mounts ----------
# add_mount-style symlink resolution and missing-path skipping are handled by
# the core; here we just declare what to mount where.

MOUNTS=(
    --mount "ro:$CLAUDE_BINARY:/home/claude/.local/bin/claude"
    # Claude config dir — rw because Claude writes session state, history, and
    # .claude.json (auth/stats) here.
    --mount "rw:${HOME}/.claude:/home/claude/.claude"
    --mount "rw:${HOME}/.claude.json:/home/claude/.claude.json"
    # TODO Phase C: stop mounting real creds; inject via the proxy instead.
    --mount "ro:${HOME}/.config/NuGet/NuGet.Config:/home/claude/.config/NuGet/NuGet.Config"
    --mount "ro:${HOME}/.config/NuGet/config/rg.config:/home/claude/.config/NuGet/config/rg.config"
    --mount "rw:${HOME}/.nuget/packages:/home/claude/.nuget/packages"
    --mount "ro:${HOME}/.dotfiles:/home/claude/.dotfiles"
    --mount "ro:${HOME}/.gitconfig:/home/claude/.gitconfig"
    --mount "ro:${HOME}/.config/git/:/home/claude/.config/git/"
    --mount "ro:${HOME}/.config/gh:/home/claude/.config/gh"
    # Host scratch dir shared with the agent (settings.json hooks write here).
    --mount "rw:/tmp/claude:/tmp/claude"
)

# settings.json hooks contain hardcoded host paths (e.g. /home/nixos/.dotfiles/
# utils/...), so .dotfiles must also resolve at its host absolute path inside
# the container.
if [[ "${HOME}/.dotfiles" != "/home/claude/.dotfiles" ]]; then
    MOUNTS+=( --mount "ro:${HOME}/.dotfiles:${HOME}/.dotfiles" )
fi

# ---------- claude-specific env ----------

ENVS=(
    # [1] Prevents Node.js OOM on large sessions / big codebases.
    --env "NODE_OPTIONS=--max-old-space-size=4096"
    # NuGet feed credentials — env var format avoids XML key name mismatch
    # between packageSources and packageSourceCredentials configs.
    --env "NuGetPackageSourceCredentials_red_gate_vsts_main_v3=${NuGetPackageSourceCredentials_red_gate_vsts_main_v3:-}"
)

# ---------- container-only OAuth token ----------
# If CLAUDE_DOCKER_OAUTH_TOKEN is set on the host, pass it in as
# CLAUDE_CODE_OAUTH_TOKEN and mask the host's ~/.claude/.credentials.json with a
# throwaway file so the container uses this token instead of the host's creds.
CRED_MASK=""
cleanup() { rm -f ${CRED_MASK:+"$CRED_MASK"}; }
trap cleanup EXIT
if [[ -n "${CLAUDE_DOCKER_OAUTH_TOKEN:-}" ]]; then
    ENVS+=( --env "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_DOCKER_OAUTH_TOKEN}" )
    CRED_MASK="$(mktemp)"
    MOUNTS+=( --mount "rw:${CRED_MASK}:/home/claude/.claude/.credentials.json" )
fi

# ---------- hand off to the generic core ----------
# Not exec'd, so the EXIT trap above runs after the core returns to clean up the
# cred mask.

"$HERE/run-agent-sandbox.sh" \
    --agent-cmd "claude --dangerously-skip-permissions" \
    "${MOUNTS[@]}" \
    "${ENVS[@]}" \
    ${WORKTREE_ARGS[@]+"${WORKTREE_ARGS[@]}"} \
    -- ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
