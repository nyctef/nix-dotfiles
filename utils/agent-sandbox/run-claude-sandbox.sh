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

# ---------- Phase C: generate placeholder configs for credential injection ----------
# Real credentials are passed to the sidecar proxy (by run-agent-sandbox.sh).
# The agent gets synthetic config files with placeholder tokens that the proxy
# swaps for real credentials in-flight.

PHASE_C_TMPDIR="$(mktemp -d)"

# GitHub CLI: synthetic hosts.yml with the placeholder token.
mkdir -p "$PHASE_C_TMPDIR/gh"
cat > "$PHASE_C_TMPDIR/gh/hosts.yml" <<'GHEOF'
github.com:
    oauth_token: SANDBOX-PLACEHOLDER-GH-TOKEN
    user: sandbox-agent
    git_protocol: https
GHEOF

# Git credential helper: returns the placeholder token for github.com.
# The proxy swaps it for the real one before it reaches GitHub.
cat > "$PHASE_C_TMPDIR/git-credential-sandbox.sh" <<'GCEOF'
#!/bin/sh
# Sandbox credential helper: returns placeholder tokens for the proxy to swap.
# Reads the protocol/host from stdin (git credential fill format).
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

# Git config overlay: use the sandbox credential helper.
# This is mounted alongside the host .gitconfig (which may have other settings
# we want to keep). We use includeIf or just override credential.helper.
mkdir -p "$PHASE_C_TMPDIR/gitconfig.d"
cat > "$PHASE_C_TMPDIR/gitconfig.d/sandbox-credentials.inc" <<'GITEOF'
[credential]
    helper = /opt/sandbox/git-credential-sandbox.sh
GITEOF

# NuGet config with placeholder PAT.
# The real NuGet.Config structure is preserved; only the credential value is
# replaced with the placeholder.
mkdir -p "$PHASE_C_TMPDIR/nuget/config"
if [[ -f "${HOME}/.config/NuGet/NuGet.Config" ]]; then
    cp "${HOME}/.config/NuGet/NuGet.Config" "$PHASE_C_TMPDIR/nuget/NuGet.Config"
fi
if [[ -f "${HOME}/.config/NuGet/config/rg.config" ]]; then
    cp "${HOME}/.config/NuGet/config/rg.config" "$PHASE_C_TMPDIR/nuget/config/rg.config"
fi

# ---------- claude-specific bind mounts ----------
# Phase C: real credentials replaced with placeholder configs. The sidecar
# proxy injects real credentials into matching outbound requests.

MOUNTS=(
    --mount "ro:$CLAUDE_BINARY:/home/claude/.local/bin/claude"
    # Claude config dir — rw because Claude writes session state, history, and
    # .claude.json (auth/stats) here.
    --mount "rw:${HOME}/.claude:/home/claude/.claude"
    --mount "rw:${HOME}/.claude.json:/home/claude/.claude.json"
    # NuGet: host config structure preserved (proxy injects real PAT).
    --mount "ro:$PHASE_C_TMPDIR/nuget/NuGet.Config:/home/claude/.config/NuGet/NuGet.Config"
    --mount "ro:$PHASE_C_TMPDIR/nuget/config/rg.config:/home/claude/.config/NuGet/config/rg.config"
    --mount "rw:${HOME}/.nuget/packages:/home/claude/.nuget/packages"
    --mount "ro:${HOME}/.dotfiles:/home/claude/.dotfiles"
    --mount "ro:${HOME}/.gitconfig:/home/claude/.gitconfig"
    --mount "ro:${HOME}/.config/git/:/home/claude/.config/git/"
    # Phase C: synthetic gh config with placeholder token (not real creds).
    --mount "ro:$PHASE_C_TMPDIR/gh:/home/claude/.config/gh"
    # Phase C: sandbox credential helper + git config overlay.
    --mount "ro:$PHASE_C_TMPDIR/git-credential-sandbox.sh:/opt/sandbox/git-credential-sandbox.sh"
    --mount "ro:$PHASE_C_TMPDIR/gitconfig.d/sandbox-credentials.inc:/opt/sandbox/sandbox-credentials.inc"
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
    # Phase C: NuGet gets the placeholder PAT. The real PAT is in the sidecar
    # proxy, which swaps it in outbound requests to VSTS feeds.
    --env "NuGetPackageSourceCredentials_red_gate_vsts_main_v3=SANDBOX-PLACEHOLDER-NUGET-PAT"
    # Phase C: Anthropic API key placeholder. The real key is in the sidecar.
    --env "ANTHROPIC_API_KEY=SANDBOX-PLACEHOLDER-ANTHROPIC-KEY"
    # Phase C: git config include for the sandbox credential helper.
    --env "GIT_CONFIG_COUNT=1"
    --env "GIT_CONFIG_KEY_0=include.path"
    --env "GIT_CONFIG_VALUE_0=/opt/sandbox/sandbox-credentials.inc"
)

# ---------- container-only OAuth token ----------
# If CLAUDE_DOCKER_OAUTH_TOKEN is set on the host, pass it in as
# CLAUDE_CODE_OAUTH_TOKEN and mask the host's ~/.claude/.credentials.json with a
# throwaway file so the container uses this token instead of the host's creds.
CRED_MASK=""
cleanup() {
    rm -f ${CRED_MASK:+"$CRED_MASK"}
    rm -rf "$PHASE_C_TMPDIR"
}
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
