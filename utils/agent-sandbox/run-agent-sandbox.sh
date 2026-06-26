#!/usr/bin/env bash
set -euo pipefail

# Generic sysbox sandbox launcher — agent-agnostic core.
#
# The caller supplies what makes a run agent-specific: the command to launch
# inside, plus any extra bind mounts and env vars. See run-claude-sandbox.sh for
# the Claude-specific wrapper that calls this.
#
# This is the NEW hardened path, developed alongside the working
# run-claude-docker.sh (which stays untouched). See README.md.
#
#   - Container runs under --runtime=sysbox-runc (unprivileged, real UID
#     remapping). The agent is the adversary; it must not be privileged.
#   - dockerd runs INSIDE the container. There is NO host Docker socket mount
#     and no --docker flag — that hop-to-host-root is exactly what we removed.
#   - /var/lib/docker is a per-instance named volume so parallel agents never
#     share an inner data-root.
#
# Phase A scope: ergonomics + isolation. Network egress is NOT yet restricted
# (Phase B). Credentials are still passed from the host (Phase C).
#
# Usage:
#   run-agent-sandbox.sh --agent-cmd <cmd> \
#       [--mount <mode>:<host>:<container>]... \
#       [--env <NAME=VALUE>]... \
#       [--worktree <name>] \
#       -- [agent args...]
#
#   --agent-cmd <cmd>   Base command launched inside the container (required),
#                       e.g. "claude --dangerously-skip-permissions". Anything
#                       after `--` is appended to it.
#   --mount <spec>      Extra bind mount; repeatable. <spec> = <mode>:<host>:
#                       <container>, mode = ro|rw. The host path is resolved
#                       (readlink -f) and Nix-store symlinks beneath it are
#                       expanded, so dotfiles symlinked into /nix/store still
#                       resolve inside the container. Missing host paths are
#                       silently skipped.
#   --env <NAME=VALUE>  Extra env var passed into the container; repeatable.
#   --worktree <name>   Branch a git worktree from HEAD and mount it as the
#                       working dir (main repo mounted ro alongside).
#
#   Run from any project directory — it mounts $PWD as the working dir.

# The launcher's support files (Dockerfile, entrypoint.sh) live alongside this
# script — both in the repo checkout and in the Nix output (default.nix copies
# the whole folder into $out/libexec/agent-sandbox), so this resolves
# correctly in both cases.
SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- parse options ----------

AGENT_CMD=""
WORKTREE_NAME=""
MOUNT_SPECS=()
ENV_SPECS=()
AGENT_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent-cmd) AGENT_CMD="$2"; shift 2 ;;
        --mount)     MOUNT_SPECS+=("$2"); shift 2 ;;
        --env)       ENV_SPECS+=("$2"); shift 2 ;;
        --worktree)  WORKTREE_NAME="$2"; shift 2 ;;
        --)          shift; AGENT_ARGS=("$@"); break ;;
        *)  echo "ERROR: unknown option '$1' (agent args go after '--')" >&2; exit 1 ;;
    esac
done

if [[ -z "$AGENT_CMD" ]]; then
    echo "ERROR: --agent-cmd is required" >&2
    exit 1
fi

# ---------- configuration ----------

BUILT_IMAGE="agent-sandbox"
CONTAINER_NAME="agent-sandbox-$$"
DOCKER_RUNTIME="sysbox-runc"
# Per-instance inner data-root volume — unique per run, removed on exit.
DATA_VOLUME="agent-sandbox-varlib-$$"

HOST_REPO_DIR="$PWD"

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

# ---------- assemble bind mounts from --mount specs ----------

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

for spec in ${MOUNT_SPECS[@]+"${MOUNT_SPECS[@]}"}; do
    # <mode>:<host>:<container> — host/container paths must not contain ':'.
    mode="${spec%%:*}"
    rest="${spec#*:}"
    host="${rest%:*}"
    container="${rest##*:}"
    if [[ "$mode" != "ro" && "$mode" != "rw" ]] || [[ -z "$host" || -z "$container" ]]; then
        echo "ERROR: bad --mount spec '$spec' (want <ro|rw>:<host>:<container>)" >&2
        exit 1
    fi
    add_mount "$mode" "$host" "$container"
done

# ---------- assemble env from --env specs ----------

EXTRA_ENV=()
for spec in ${ENV_SPECS[@]+"${ENV_SPECS[@]}"}; do
    EXTRA_ENV+=(-e "$spec")
done

# ---------- cleanup ----------

cleanup() {
    # Per-instance inner data-root volume is disposable.
    docker volume rm -f "$DATA_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------- run ----------

echo "Starting agent in sysbox sandbox..."
echo "  Working dir  : $HOST_PROJECT_DIR"
if [[ -n "$WORKTREE_NAME" ]]; then
echo "  Worktree     : $WORKTREE_NAME (branch from $(git -C "$HOST_REPO_DIR" rev-parse --short HEAD))"
echo "  Main repo    : $HOST_REPO_DIR (mounted ro)"
fi
echo "  Runtime      : $DOCKER_RUNTIME (inner dockerd, no host socket)"
echo "  Agent command: $AGENT_CMD"
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
    \
    `# ---- Caller-supplied bind mounts (agent binary, configs, creds, ...) ----` \
    ${OPTIONAL_MOUNTS[@]+"${OPTIONAL_MOUNTS[@]}"} \
    \
    `# ---- Environment ----` \
    -e "HOME=/home/claude" \
    -e "TERM=${TERM:-xterm-256color}" \
    -e "SANDBOX_AGENT_CMD=$AGENT_CMD" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    \
    "$BUILT_IMAGE" \
    \
    -- ${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}
