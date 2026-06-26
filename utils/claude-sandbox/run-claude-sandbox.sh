#!/usr/bin/env bash
set -euo pipefail

# Run Claude Code (YOLO mode) inside a sysbox-isolated sandbox.
#
# This is the NEW hardened path, developed alongside the working
# run-claude-docker.sh (which stays untouched). See SANDBOX-PLAN.md.
#
# Differences from run-claude-docker.sh:
#   - Container runs under --runtime=sysbox-runc (unprivileged, real UID
#     remapping). The agent is the adversary; it must not be privileged.
#   - dockerd runs INSIDE the container. There is NO host Docker socket mount
#     and no --docker flag — that hop-to-host-root is exactly what we removed.
#   - /var/lib/docker is a per-instance named volume so parallel agents never
#     share an inner data-root.
#
# Phase A scope: ergonomics + isolation. Network egress is NOT yet restricted
# (Phase B). Credentials are still mounted from the host (Phase C).
#
# Usage: run-claude-sandbox.sh [--worktree <name>] [claude args...]
#   Run from any project directory — it mounts $PWD as the working dir.

# The launcher's support files (Dockerfile, entrypoint.sh) live alongside this
# script — both in the repo checkout and in the Nix output (default.nix copies
# the whole folder into $out/libexec/claude-sandbox), so this resolves
# correctly in both cases.
SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- parse options ----------

WORKTREE_NAME=""
CLAUDE_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --worktree)
            WORKTREE_NAME="$2"
            shift 2
            ;;
        *)  CLAUDE_ARGS+=("$1"); shift ;;
    esac
done

# ---------- configuration ----------

BUILT_IMAGE="claude-sandbox"
CONTAINER_NAME="claude-sandbox-$$"
DOCKER_RUNTIME="sysbox-runc"
# Per-instance inner data-root volume — unique per run, removed on exit.
DATA_VOLUME="claude-sandbox-varlib-$$"

HOST_REPO_DIR="$PWD"
CLAUDE_BINARY="$(readlink -f ~/.local/bin/claude)"

# ---------- worktree setup (copied verbatim from run-claude-docker.sh) ----------

if [[ -n "$WORKTREE_NAME" ]]; then
    REPO_BASENAME="$(basename "$HOST_REPO_DIR")"
    WORKTREE_BASE="$(dirname "$HOST_REPO_DIR")/.$REPO_BASENAME-worktrees"
    WORKTREE_DIR="$WORKTREE_BASE/$WORKTREE_NAME"

    if [[ -d "$WORKTREE_DIR" ]]; then
        echo "Reusing existing worktree: $WORKTREE_DIR"
        if [[ -n "$(git -C "$WORKTREE_DIR" status --porcelain)" ]]; then
            echo "ERROR: worktree at $WORKTREE_DIR has uncommitted changes; refusing to reset." >&2
            echo "       Commit, stash, or discard them, then re-run." >&2
            exit 1
        fi
        BRANCH_SHA="$(git -C "$HOST_REPO_DIR" rev-parse "refs/heads/$WORKTREE_NAME")"
        git -C "$WORKTREE_DIR" switch -C "$WORKTREE_NAME" "$BRANCH_SHA"
    else
        mkdir -p "$WORKTREE_BASE"
        if git -C "$HOST_REPO_DIR" show-ref --verify --quiet "refs/heads/$WORKTREE_NAME"; then
            echo "Creating worktree '$WORKTREE_NAME' from existing branch..."
            git -C "$HOST_REPO_DIR" worktree add "$WORKTREE_DIR" "$WORKTREE_NAME"
        else
            CURRENT_HEAD="$(git -C "$HOST_REPO_DIR" rev-parse HEAD)"
            echo "Creating worktree '$WORKTREE_NAME' from $(git -C "$HOST_REPO_DIR" rev-parse --short HEAD)..."
            git -C "$HOST_REPO_DIR" worktree add -b "$WORKTREE_NAME" "$WORKTREE_DIR" "$CURRENT_HEAD"
        fi
    fi

    HOST_PROJECT_DIR="$WORKTREE_DIR"
else
    HOST_PROJECT_DIR="$HOST_REPO_DIR"
fi

# ---------- pre-flight checks ----------

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed or not in PATH" >&2
    exit 1
fi

if [[ ! -x "$CLAUDE_BINARY" ]]; then
    echo "ERROR: claude binary not found at $CLAUDE_BINARY" >&2
    exit 1
fi

# Fail early with a clear message if the sysbox runtime isn't registered —
# this is the whole point of the new path.
if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q "$DOCKER_RUNTIME"; then
    echo "ERROR: docker runtime '$DOCKER_RUNTIME' is not registered." >&2
    echo "       Ensure virtualisation.sysbox.enable = true and rebuild." >&2
    exit 1
fi

# ---------- build image if needed ----------

DOTNET_SDK_VERSION="$(dotnet --version)"
FLYWAY_VERSION="$(flyway version -outputType=json 2>/dev/null | jq -r '.version')"

echo "Building Docker image '$BUILT_IMAGE'..."
# Real build context (the support dir) so the Dockerfile can COPY entrypoint.sh
# — unlike the old `docker build -` stdin build with no context.
docker build \
    --build-arg "DOTNET_SDK_VERSION=$DOTNET_SDK_VERSION" \
    --build-arg "FLYWAY_VERSION=$FLYWAY_VERSION" \
    -t "$BUILT_IMAGE" \
    -f "$SUPPORT_DIR/Dockerfile" \
    "$SUPPORT_DIR"

# ---------- optional mounts (copied from run-claude-docker.sh) ----------

OPTIONAL_MOUNTS=()

# Nix/Home Manager dotfiles are symlinks into /nix/store, which doesn't exist
# in the container. For each bind-mounted dir, resolve symlinks whose targets
# fall outside the dir and add individual file mounts at the dereferenced path.
resolve_external_symlinks() {
    local host_dir="${1%/}" container_dir="${2%/}" mode="$3"
    local real_host_dir
    real_host_dir="$(readlink -f "$host_dir")"
    while IFS= read -r -d '' link; do
        local target
        target="$(readlink -f "$link")"
        [[ "$target" == "$real_host_dir"/* ]] && continue
        local rel="${link#"$host_dir"/}"
        OPTIONAL_MOUNTS+=(-v "${target}:${container_dir}/${rel}:${mode}")
    done < <(find "$host_dir" -maxdepth 2 -type l -print0 2>/dev/null)
}

add_mount() {
    local mode="$1" src="$2" dst="$3"
    local resolved
    resolved="$(readlink -f "$src" 2>/dev/null)" || resolved="$src"
    if [[ -e "$resolved" ]]; then
        OPTIONAL_MOUNTS+=(-v "${resolved}:${dst}:${mode}")
        if [[ -d "$resolved" ]]; then
            resolve_external_symlinks "$src" "$dst" ro
        fi
    fi
}

add_mount rw "${HOME}/.claude"      "/home/claude/.claude"
add_mount rw "${HOME}/.claude.json" "/home/claude/.claude.json"
# TODO Phase C: stop mounting real creds; inject via the proxy instead.
add_mount ro "${HOME}/.config/NuGet/NuGet.Config" "/home/claude/.config/NuGet/NuGet.Config"
add_mount ro "${HOME}/.config/NuGet/config/rg.config" "/home/claude/.config/NuGet/config/rg.config"
add_mount rw "${HOME}/.nuget/packages" "/home/claude/.nuget/packages"
add_mount ro "${HOME}/.dotfiles"    "/home/claude/.dotfiles"
if [[ "${HOME}/.dotfiles" != "/home/claude/.dotfiles" ]]; then
    add_mount ro "${HOME}/.dotfiles" "${HOME}/.dotfiles"
fi
add_mount ro "${HOME}/.gitconfig"   "/home/claude/.gitconfig"
add_mount ro "${HOME}/.config/git/" "/home/claude/.config/git/"
add_mount ro "${HOME}/.config/gh"   "/home/claude/.config/gh"

# ---------- container-only OAuth token (copied from run-claude-docker.sh) ----------

EXTRA_ENV=()
CRED_MASK=""
if [[ -n "${CLAUDE_DOCKER_OAUTH_TOKEN:-}" ]]; then
    EXTRA_ENV+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_DOCKER_OAUTH_TOKEN}")
    CRED_MASK="$(mktemp)"
    OPTIONAL_MOUNTS+=(-v "${CRED_MASK}:/home/claude/.claude/.credentials.json:rw")
fi

# ---------- cleanup ----------

cleanup() {
    rm -f ${CRED_MASK:+"$CRED_MASK"}
    # Per-instance inner data-root volume is disposable.
    docker volume rm -f "$DATA_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------- run ----------

echo "Starting Claude Code in sysbox sandbox..."
echo "  Working dir  : $HOST_PROJECT_DIR"
if [[ -n "$WORKTREE_NAME" ]]; then
echo "  Worktree     : $WORKTREE_NAME (branch from $(git -C "$HOST_REPO_DIR" rev-parse --short HEAD))"
echo "  Main repo    : $HOST_REPO_DIR (mounted ro)"
fi
echo "  Runtime      : $DOCKER_RUNTIME (inner dockerd, no host socket)"
echo "  Claude binary: $CLAUDE_BINARY"
echo ""

if [[ -n "$WORKTREE_NAME" ]]; then
    PROJECT_MOUNTS=(
        -v "$HOST_PROJECT_DIR:$HOST_PROJECT_DIR:rw"
        -v "$HOST_REPO_DIR:$HOST_REPO_DIR:rw"
        -w "$HOST_PROJECT_DIR"
    )
else
    PROJECT_MOUNTS=(
        -v "$HOST_PROJECT_DIR:/home/claude/project:rw"
    )
fi

exec docker run \
    --rm \
    -it \
    --name "$CONTAINER_NAME" \
    --runtime="$DOCKER_RUNTIME" \
    \
    `# ---- Inner Docker data-root: per-instance volume (not shared) ----` \
    -v "$DATA_VOLUME:/var/lib/docker" \
    \
    `# ---- Project / worktree mounts ----` \
    "${PROJECT_MOUNTS[@]}" \
    -v "/tmp/claude:/tmp/claude:rw" \
    \
    `# ---- Conditional mounts (creds, dotfiles, nix-resolved symlinks) ----` \
    "${OPTIONAL_MOUNTS[@]}" \
    \
    `# ---- Claude binary itself ----` \
    -v "$CLAUDE_BINARY:/home/claude/.local/bin/claude:ro" \
    \
    `# ---- Environment ----` \
    -e "HOME=/home/claude" \
    -e "TERM=${TERM:-xterm-256color}" \
    -e "NODE_OPTIONS=--max-old-space-size=4096" \
    -e "NuGetPackageSourceCredentials_red_gate_vsts_main_v3=${NuGetPackageSourceCredentials_red_gate_vsts_main_v3:-}" \
    "${EXTRA_ENV[@]}" \
    \
    "$BUILT_IMAGE" \
    \
    -- "${CLAUDE_ARGS[@]}"
