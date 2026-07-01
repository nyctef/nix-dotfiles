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

cleanup_pi() { rm -rf "$PHASE_C_TMPDIR"; }
trap cleanup_pi EXIT

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
