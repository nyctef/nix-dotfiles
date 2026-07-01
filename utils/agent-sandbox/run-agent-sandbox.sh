#!/usr/bin/env bash
set -euo pipefail

# Generic sysbox sandbox launcher — agent-agnostic core (Phase B.1: sidecar).
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
# Phase B.1: L7 egress enforcement via a sidecar proxy container. The agent
# container sits on an --internal Docker network whose only route to the
# internet goes through the sidecar (mitmproxy). Even if the agent gains root
# and flushes iptables inside its own container, the sidecar's enforcement
# is unreachable — closing the last residual risk from Phase B.
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

AGENT_IMAGE="agent-sandbox"
SIDECAR_IMAGE="agent-sandbox-sidecar"
CONTAINER_NAME="agent-sandbox-$$"
SIDECAR_NAME="agent-sandbox-sidecar-$$"
DOCKER_RUNTIME="sysbox-runc"

# Per-instance resources — unique per run, removed on exit.
DATA_VOLUME="agent-sandbox-varlib-$$"
CA_VOLUME="agent-sandbox-ca-$$"
INTERNAL_NET="sandbox-internal-$$"

# Sandbox network: Docker --internal network with an auto-assigned subnet.
# --internal adds host-level iptables rules (DOCKER-INTERNAL chain) that DROP
# any packet on the bridge with a non-subnet destination IP. This provides
# mandatory enforcement: even if the agent gains root and ignores HTTP_PROXY,
# it cannot reach external IPs. The only way out is through the sidecar proxy,
# which the agent reaches via its internal IP (in-subnet, allowed by Docker).
# We let Docker pick the subnet to avoid collisions when running in parallel.
PROXY_PORT=8080

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

# ---------- build images ----------

DOTNET_SDK_VERSION="$(dotnet --version)"
FLYWAY_VERSION="$(flyway version -outputType=json 2>/dev/null | jq -r '.version')"

echo "Building Docker images..."

# Agent image (sysbox, inner dockerd, developer tools)
docker build \
    --build-arg "DOTNET_SDK_VERSION=$DOTNET_SDK_VERSION" \
    --build-arg "FLYWAY_VERSION=$FLYWAY_VERSION" \
    -t "$AGENT_IMAGE" \
    -f "$SUPPORT_DIR/Dockerfile" \
    "$SUPPORT_DIR"

# Sidecar image (mitmproxy + iptables, lightweight)
docker build \
    -t "$SIDECAR_IMAGE" \
    -f "$SUPPORT_DIR/Dockerfile.sidecar" \
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
        target="$(readlink -f "$link")" || continue
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
        # Skip symlink resolution for /nix/store — we mount the whole thing,
        # and scanning it is extremely slow (thousands of entries).
        if [[ -d "$resolved" && "$resolved" != "/nix/store" ]]; then
            resolve_external_symlinks "$src" "$dst" "$mode"
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

# ---------- resolve host credentials for sidecar injection (Phase C) ----------
# Real credentials are read here on the host and passed ONLY to the sidecar
# container. The agent container never sees them — it gets placeholder tokens
# instead. The sidecar proxy addon (cred-inject.py) swaps placeholders for
# real credentials in outbound requests.

SIDECAR_CRED_ENV=()

# GitHub token: try gh CLI first, then GITHUB_TOKEN env var.
if command -v gh &>/dev/null; then
    _GH_TOKEN="$(gh auth token 2>/dev/null)" || true
else
    _GH_TOKEN=""
fi
_GH_TOKEN="${_GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -n "$_GH_TOKEN" ]]; then
    SIDECAR_CRED_ENV+=(-e "SANDBOX_CRED_GITHUB_TOKEN=$_GH_TOKEN")
    echo "  Credential: GitHub token → sidecar (placeholder to agent)"
fi
unset _GH_TOKEN

# NuGet PAT: from the same env var the old mount used.
_NUGET_PAT="${SANDBOX_CRED_NUGET_PAT:-${NuGetPackageSourceCredentials_red_gate_vsts_main_v3:-}}"
if [[ -n "$_NUGET_PAT" ]]; then
    SIDECAR_CRED_ENV+=(-e "SANDBOX_CRED_NUGET_PAT=$_NUGET_PAT")
    echo "  Credential: NuGet PAT → sidecar (placeholder to agent)"
fi
unset _NUGET_PAT

# Anthropic API key.
_ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
if [[ -n "$_ANTHROPIC_KEY" ]]; then
    SIDECAR_CRED_ENV+=(-e "SANDBOX_CRED_ANTHROPIC_KEY=$_ANTHROPIC_KEY")
    echo "  Credential: Anthropic API key → sidecar (placeholder to agent)"
fi
unset _ANTHROPIC_KEY

# Claude Code OAuth token (Bearer auth for api.anthropic.com).
_CLAUDE_OAUTH="${CLAUDE_DOCKER_OAUTH_TOKEN:-}"
if [[ -n "$_CLAUDE_OAUTH" ]]; then
    SIDECAR_CRED_ENV+=(-e "SANDBOX_CRED_CLAUDE_OAUTH=$_CLAUDE_OAUTH")
    echo "  Credential: Claude OAuth token → sidecar (placeholder to agent)"
fi
unset _CLAUDE_OAUTH

# ---------- cleanup ----------

cleanup() {
    echo ""
    echo "Cleaning up sandbox resources..."
    # Stop sidecar (agent container cleans itself via --rm)
    docker stop -t 2 "$SIDECAR_NAME" 2>/dev/null || true
    docker rm -f "$SIDECAR_NAME" 2>/dev/null || true
    # Remove the internal network (must happen after containers are gone)
    docker network rm "$INTERNAL_NET" 2>/dev/null || true
    # Remove per-instance volumes
    docker volume rm -f "$CA_VOLUME" 2>/dev/null || true
    docker volume rm -f "$DATA_VOLUME" 2>/dev/null || true
}
trap cleanup EXIT

# ---------- create network and volumes ----------

FIREWALL_DISABLED="${SANDBOX_DISABLE_FIREWALL:-}"

if [[ "$FIREWALL_DISABLED" != "1" ]]; then
    echo "Creating sandbox network ($INTERNAL_NET, --internal, auto-subnet)..."
    docker network create --internal "$INTERNAL_NET"

    echo "Creating CA-sharing volume ($CA_VOLUME)..."
    docker volume create "$CA_VOLUME" >/dev/null

    # ---------- start sidecar ----------
    # Use docker create + network connect + start to attach both networks before
    # the entrypoint runs. This way the sidecar sees both interfaces at startup
    # and can correctly identify external (default route) vs internal.

    echo "Starting sidecar proxy ($SIDECAR_NAME)..."

    # Start sidecar on the default bridge (internet access), then attach to
    # the internal network. No NET_ADMIN or ip_forward needed — the sidecar
    # is a simple forward proxy, not a NAT gateway. Docker's --internal
    # network provides the mandatory enforcement.
    docker run -d \
        --name "$SIDECAR_NAME" \
        --network bridge \
        -v "$CA_VOLUME:/shared-ca" \
        ${SIDECAR_CRED_ENV[@]+"${SIDECAR_CRED_ENV[@]}"} \
        "$SIDECAR_IMAGE" \
        >/dev/null

    docker network connect "$INTERNAL_NET" "$SIDECAR_NAME"

    # Discover the sidecar's auto-assigned IP on the internal network.
    SIDECAR_INTERNAL_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$INTERNAL_NET\").IPAddress}}" "$SIDECAR_NAME")"
    if [[ -z "$SIDECAR_INTERNAL_IP" ]]; then
        echo "ERROR: could not determine sidecar IP on $INTERNAL_NET" >&2
        exit 1
    fi

    # Wait for sidecar to be ready (CA generated, iptables configured)
    echo "Waiting for sidecar to be ready..."
    for _ in $(seq 1 60); do
        # Check the CA volume for the readiness signal
        if docker run --rm -v "$CA_VOLUME:/shared-ca:ro" alpine \
            test -f /shared-ca/.sidecar-ready 2>/dev/null; then
            break
        fi
        # Check sidecar is still running
        if ! docker inspect --format '{{.State.Running}}' "$SIDECAR_NAME" 2>/dev/null | grep -q true; then
            echo "ERROR: sidecar exited during startup. Logs:" >&2
            docker logs "$SIDECAR_NAME" 2>&1 | tail -n 40 >&2 || true
            exit 1
        fi
        sleep 0.5
    done

    # Verify readiness
    if ! docker run --rm -v "$CA_VOLUME:/shared-ca:ro" alpine \
        test -f /shared-ca/.sidecar-ready 2>/dev/null; then
        echo "ERROR: sidecar not ready within 30s. Logs:" >&2
        docker logs "$SIDECAR_NAME" 2>&1 | tail -n 40 >&2 || true
        exit 1
    fi

    echo "Sidecar proxy ready."

    # Agent on --internal network only. No --dns override needed: the agent
    # doesn't need external DNS because HTTP_PROXY handles hostname resolution
    # (the proxy resolves DNS from its bridge interface). Docker's embedded DNS
    # (127.0.0.11) still resolves container names on the internal network.
    PROXY_URL="http://${SIDECAR_INTERNAL_IP}:${PROXY_PORT}"
    NETWORK_ARGS=(--network "$INTERNAL_NET")
    SIDECAR_ENV=(-e "SANDBOX_PROXY_URL=$PROXY_URL")
    CA_MOUNT=(-v "$CA_VOLUME:/shared-ca:ro")
else
    echo "WARN: sidecar proxy disabled (SANDBOX_DISABLE_FIREWALL=1)." >&2
    NETWORK_ARGS=()
    SIDECAR_ENV=()
    CA_MOUNT=()
fi

# ---------- run ----------

echo ""
echo "Starting agent in sysbox sandbox..."
echo "  Working dir  : $HOST_PROJECT_DIR"
if [[ -n "$WORKTREE_NAME" ]]; then
echo "  Worktree     : $WORKTREE_NAME (branch from $(git -C "$HOST_REPO_DIR" rev-parse --short HEAD))"
echo "  Main repo    : $HOST_REPO_DIR (mounted ro)"
fi
echo "  Runtime      : $DOCKER_RUNTIME (inner dockerd, no host socket)"
if [[ "$FIREWALL_DISABLED" != "1" ]]; then
echo "  Egress       : sidecar proxy ($SIDECAR_NAME) on $INTERNAL_NET (--internal)"
echo "  Proxy URL    : $PROXY_URL"
fi
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

# Run agent in foreground (not exec'd, so EXIT trap runs for cleanup).
docker run \
    --rm \
    -i $([ -t 0 ] && echo '-t') \
    --name "$CONTAINER_NAME" \
    --runtime="$DOCKER_RUNTIME" \
    \
    `# ---- Network: internal only (sidecar is the only gateway) ----` \
    ${NETWORK_ARGS[@]+"${NETWORK_ARGS[@]}"} \
    \
    `# ---- Inner Docker data-root: per-instance volume (not shared) ----` \
    -v "$DATA_VOLUME:/var/lib/docker" \
    \
    `# ---- CA from sidecar: shared via Docker volume ----` \
    ${CA_MOUNT[@]+"${CA_MOUNT[@]}"} \
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
    -e "SANDBOX_DISABLE_FIREWALL=${SANDBOX_DISABLE_FIREWALL:-}" \
    ${SIDECAR_ENV[@]+"${SIDECAR_ENV[@]}"} \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    \
    "$AGENT_IMAGE" \
    \
    -- ${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}
