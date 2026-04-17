#!/usr/bin/env bash
set -euo pipefail

# Run Claude Code in YOLO mode (--dangerously-skip-permissions) inside a Docker container.
# This avoids sandbox issues by giving Claude full access inside the container,
# while the container itself provides isolation from the host.
#
# Usage: run-claude-docker.sh [--docker] [--worktree <name>] [claude args...]
#   Run from any project directory — it mounts $PWD as the working dir.
#
# Options:
#   --docker   Mount the host Docker socket into the container so Claude can
#              run docker commands (e.g. for test databases).
#
#              WARNING: This effectively gives the container full control over
#              the host Docker daemon, which is equivalent to root on the host.
#              Claude can spawn new containers that bypass the in-container
#              firewall entirely (spawned containers get their own network
#              namespace, so our iptables rules don't apply to them). It can
#              also mount arbitrary host paths or use --privileged.
#
#              In short: --docker makes the firewall useless as an exfiltration
#              guard, since Claude can just `docker run` a container with
#              unrestricted network access.
#
#              TODO: investigate Docker socket proxies to restrict which API
#              calls Claude can make. Options:
#                - tecnativa/docker-socket-proxy — lightweight HAProxy-based
#                  filter, can whitelist specific Docker API endpoints
#                  (e.g. allow container create/start/stop but deny --privileged
#                  and host volume mounts)
#                - Sysbox — a container runtime that provides Docker-in-Docker
#                  isolation without needing the host socket at all
#                - docker daemon --userns-remap — daemon-wide user namespace
#                  remapping, limits what mounted host files are accessible
#
#   --worktree <name>
#              Create (or reuse) a git worktree branching from the current
#              HEAD and mount it as the container's primary working directory.
#              The worktree is created at ../.<repo>-worktrees/<name> on the
#              host. The main repo is mounted read-only (to prevent Claude
#              from accidentally committing there). Both are mounted at
#              their host absolute paths so git's worktree cross-references
#              resolve correctly. The branch is named <name> (no prefix).

# ---------- parse options ----------

MOUNT_DOCKER=false
WORKTREE_NAME=""
CLAUDE_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker) MOUNT_DOCKER=true; shift ;;
        --worktree)
            WORKTREE_NAME="$2"
            shift 2
            ;;
        *)  CLAUDE_ARGS+=("$1"); shift ;;
    esac
done

# ---------- configuration ----------

BUILT_IMAGE="claude-yolo"
CONTAINER_NAME="claude-yolo-$$"
DOCKER_SOCK="/var/run/docker.sock"

HOST_REPO_DIR="$PWD"
CLAUDE_BINARY="$(readlink -f ~/.local/bin/claude)"

# ---------- worktree setup ----------

if [[ -n "$WORKTREE_NAME" ]]; then
    REPO_BASENAME="$(basename "$HOST_REPO_DIR")"
    WORKTREE_BASE="$(dirname "$HOST_REPO_DIR")/.$REPO_BASENAME-worktrees"
    WORKTREE_DIR="$WORKTREE_BASE/$WORKTREE_NAME"

    if [[ -d "$WORKTREE_DIR" ]]; then
        echo "Reusing existing worktree: $WORKTREE_DIR"
    else
        mkdir -p "$WORKTREE_BASE"
        CURRENT_HEAD="$(git -C "$HOST_REPO_DIR" rev-parse HEAD)"
        echo "Creating worktree '$WORKTREE_NAME' from $(git -C "$HOST_REPO_DIR" rev-parse --short HEAD)..."
        git -C "$HOST_REPO_DIR" worktree add -b "$WORKTREE_NAME" "$WORKTREE_DIR" "$CURRENT_HEAD"
    fi

    HOST_PROJECT_DIR="$WORKTREE_DIR"
else
    HOST_PROJECT_DIR="$HOST_REPO_DIR"
fi

# ---------- Dockerfile (inline) ----------
# Kept in a variable for readability; piped to `docker build` below.

read -r -d '' DOCKERFILE <<'EOF' || true
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Minimal first pass: install ca-certificates so apt can trust the HTTPS
# third-party repos we add below. Everything else is deferred to the single
# big install after the repos are registered.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates

# Docker CLI repo. ADD is executed by the Docker builder (not inside the
# image), so it doesn't need curl or ca-certificates in the image.
ADD --chmod=0644 https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.asc
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list

# Microsoft repo (for PowerShell). We register the key + list by hand rather
# than via the packages-microsoft-prod .deb, because that deb depends on
# ca-certificates and the dpkg-level dependency check rejects installing
# it standalone.
ADD --chmod=0644 https://packages.microsoft.com/keys/microsoft.asc /etc/apt/keyrings/microsoft.asc
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.asc] \
      https://packages.microsoft.com/ubuntu/24.04/prod $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
      > /etc/apt/sources.list.d/microsoft-prod.list

# One big install covering everything — including docker-ce-cli and
# powershell from the third-party repos registered just above. This image
# is only used locally, so we intentionally leave /var/lib/apt/lists/* in
# place: keeping the cache lets Claude apt-get install extras at runtime
# without waiting for a re-fetch.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        gh \
        jq \
        less \
        python3 python-is-python3 \
        # [4] procps — gives Claude ps/top/kill so it can inspect and manage
        #     processes inside the container (e.g. checking if a build is hung)
        procps \
        # [5] sudo — lets Claude apt-get install extra packages at runtime
        #     without needing to be root
        sudo \
        # [3] firewall deps — iptables/ipset/iproute2/dnsutils/aggregate are
        #     used by init-firewall.sh to set up a default-deny outbound
        #     firewall that only whitelists Claude API, GitHub, etc.
        #     Prevents accidental or malicious exfiltration to unknown hosts.
        #     dnsmasq provides DNS-aware firewalling: it auto-adds resolved
        #     IPs to the ipset on every DNS query, so CDN IP rotation is
        #     handled transparently without rebuilding the image.
        iptables \
        ipset \
        iproute2 \
        dnsutils \
        aggregate \
        dnsmasq \
        # Docker CLI — only the client, no daemon. Talks to the host daemon
        # via the bind-mounted socket. Needed for tests that spin up on-demand
        # containers (e.g. test databases).
        docker-ce-cli \
        docker-compose-plugin \
        # Java + Maven
        default-jdk-headless \
        maven \
        # PowerShell (from the Microsoft repo added above)
        powershell

# Non-root user matching typical host UID (1000).
# The DOCKER_GID arg is set at build time from the host socket's group so
# the claude user can talk to the Docker daemon without sudo.
# Ubuntu 24.04 ships with a 'ubuntu' user at UID/GID 1000. Remove it so we
# can create our own user at the same UID to match the host.
ARG DOCKER_GID=965
RUN userdel -r ubuntu 2>/dev/null || true && \
    groupadd -f -g 1000 claude && \
    useradd -m -u 1000 -g claude -s /bin/bash claude && \
    (groupadd -f -g ${DOCKER_GID} docker || true) && \
    usermod -aG docker claude

# .NET 10 SDK — needed for building/testing the project
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    bash /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet && \
    ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet && \
    rm /tmp/dotnet-install.sh
ENV DOTNET_ROOT=/usr/share/dotnet

# Jujutsu (jj) — modern VCS, installed from GitHub releases
RUN JJ_VERSION="0.40.0" && \
    curl -fsSL "https://github.com/jj-vcs/jj/releases/download/v${JJ_VERSION}/jj-v${JJ_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/jj.tar.gz && \
    tar -xzf /tmp/jj.tar.gz -C /usr/local/bin ./jj && \
    chmod +x /usr/local/bin/jj && \
    rm /tmp/jj.tar.gz

# [5] Sudo for the claude user — restricted to package management only.
# The container starts as root for firewall init, then drops to the claude
# user. This sudoers rule lets Claude install packages at runtime but
# prevents it from modifying the firewall (iptables, ipset, dnsmasq, etc.).
RUN echo "claude ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg" \
    > /etc/sudoers.d/claude && \
    chmod 0440 /etc/sudoers.d/claude

# NuGet reads config from ~/.nuget/NuGet/, which on the host is a symlink to
# ~/.config/NuGet/. Replicate that layout so bind-mounted configs at
# ~/.config/NuGet/ are found by NuGet at its expected path.
RUN mkdir -p /home/claude/.nuget /home/claude/.config/NuGet /home/claude/.local && \
    ln -s /home/claude/.config/NuGet /home/claude/.nuget/NuGet && \
    chown -R claude:claude /home/claude/.nuget /home/claude/.config /home/claude/.local

# ---- Firewall: domain allowlist + build-time IP warm-start ----
# /etc/firewall-domains.txt is the single source of truth for allowed domains.
# At build time we resolve them to IPs for a warm-start ipset (fast first
# connection). At runtime, dnsmasq uses the same list to dynamically add
# freshly-resolved IPs to the ipset on every DNS query, so CDN IP rotation
# (Akamai, Azure Front Door, etc.) is handled transparently.

# The domain list — one per line, used by both build-time DNS resolution
# and the runtime dnsmasq --ipset configuration. dnsmasq's --ipset
# automatically matches subdomains too, so e.g. "sentry.io" also covers
# "o123.ingest.sentry.io" without needing explicit entries.
RUN printf '%s\n' \
        api.anthropic.com \
        statsig.anthropic.com \
        statsig.com \
        sentry.io \
        registry.npmjs.org \
        registry-1.docker.io \
        auth.docker.io \
        production.cloudflare.docker.com \
        download.docker.com \
        archive.ubuntu.com \
        security.ubuntu.com \
        api.nuget.org \
        azureedge.net \
        dotnetcli.azureedge.net \
        repo1.maven.org \
        repo.gradle.org \
        s3.amazonaws.com \
        maven.pkg.github.com \
        maven-central.storage-download.googleapis.com \
        red-gate.pkgs.visualstudio.com \
        docs.oracle.com \
        postgresql.org \
        dev.mysql.com \
    > /etc/firewall-domains.txt

# GitHub IP ranges (CIDR blocks from the GitHub API, not individual IPs)
RUN curl -sf https://api.github.com/meta | \
    jq -r '(.web + .api + .git)[]' | aggregate -q \
    > /etc/firewall-github-cidrs.txt

# Azure Storage IP ranges (where Azure DevOps stores NuGet package blobs
# on *.blob.core.windows.net). Fetched from Microsoft's weekly-updated
# service tags JSON.
RUN DOWNLOAD_PAGE=$(curl -sf 'https://www.microsoft.com/en-us/download/details.aspx?id=56519') && \
    JSON_URL=$(echo "$DOWNLOAD_PAGE" | grep -oP 'https://download\.microsoft\.com/download/[^"]+\.json' | head -1) && \
    curl -sf "$JSON_URL" | \
    jq -r '.values[] | select(.name == "Storage") | .properties.addressPrefixes[]' | \
    grep -v ':' \
    > /etc/firewall-azure-storage-cidrs.txt

# Warm-start: resolve domain list to IPs at build time so the ipset is
# pre-populated before dnsmasq handles any queries. These go stale over
# time but dnsmasq will dynamically add fresh IPs at runtime.
RUN while read -r domain; do \
        dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}'; \
    done < /etc/firewall-domains.txt | sort -u > /etc/firewall-resolved-ips.txt

# Container starts as root so init-firewall.sh can configure iptables/ipset
# without sudo. The firewall script drops to the claude user after setup.
WORKDIR /home/claude/project
EOF

# ---------- firewall init script (inline) ----------
# [3] Sets up a DNS-aware outbound firewall using dnsmasq + iptables + ipset.
#     dnsmasq intercepts all DNS queries and dynamically adds resolved IPs to
#     the ipset, so CDN IP rotation is handled transparently. Build-time
#     resolved IPs provide a warm-start so the first connection doesn't race
#     against DNS. Requires --cap-add=NET_ADMIN, --cap-add=NET_RAW, and
#     --dns 127.0.0.1 on docker run.

read -r -d '' FIREWALL_SCRIPT <<'FWEOF' || true
#!/bin/bash
set -euo pipefail

echo "Configuring firewall..."

HOST_IP=$(ip route | grep default | cut -d" " -f3)
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")

# ---- Start dnsmasq as a local DNS-aware firewall helper ----
# We point dnsmasq upstream at the host/gateway DNS (the Docker bridge
# gateway, typically 172.17.0.1). The container's --dns 127.0.0.1 routes
# all DNS through dnsmasq, which auto-adds resolved IPs to the ipset.
# Note: Docker's embedded DNS at 127.0.0.11 is only available when using
# user-defined networks; on the default bridge it doesn't exist.

# Create the ipset early — dnsmasq needs it to exist before it can add entries
ipset create allowed-domains hash:net

# Build the --ipset argument: all domains in the allowlist map to the same
# ipset. dnsmasq --ipset format: /domain1/domain2/.../ipset-name
# dnsmasq's --ipset automatically matches subdomains, so "sentry.io"
# also covers "o123.ingest.sentry.io" etc.
IPSET_DOMAINS=""
while read -r domain; do
    [ -n "$domain" ] && IPSET_DOMAINS="${IPSET_DOMAINS}/${domain}"
done < /etc/firewall-domains.txt

# Also add github.com (covered by CIDR ranges at build time, but dnsmasq
# can catch any new IPs from DNS too)
IPSET_DOMAINS="${IPSET_DOMAINS}/github.com"

# HOST_DNS is passed in from the host's /etc/resolv.conf. Fall back to
# the default gateway if not set (works when the host runs a DNS resolver
# on the bridge interface, but not on WSL2 where DNS is on a separate IP).
UPSTREAM_DNS="${HOST_DNS:-$HOST_IP}"
echo "Using upstream DNS: $UPSTREAM_DNS"

dnsmasq \
    --no-resolv \
    --server="$UPSTREAM_DNS" \
    --listen-address=127.0.0.1 \
    --bind-interfaces \
    --ipset="${IPSET_DOMAINS}/allowed-domains" \
    --log-facility=/var/log/dnsmasq.log \
    --log-queries

echo "dnsmasq started (upstream: $UPSTREAM_DNS, ipset: allowed-domains)"

# Flush filter table only. Leave nat/mangle alone.
iptables -F; iptables -X

# Allow DNS: local dnsmasq on loopback, and dnsmasq's upstream (gateway)
iptables -A OUTPUT -d 127.0.0.1 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.1 -p tcp --dport 53 -j ACCEPT
# dnsmasq needs to reach the upstream DNS (may be outside the Docker
# bridge subnet, e.g. WSL2's DNS at 10.255.255.254)
iptables -A OUTPUT -d "$UPSTREAM_DNS" -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -d "$UPSTREAM_DNS" -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -s "$UPSTREAM_DNS" -p udp --sport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Warm-start: load build-time resolved IPs (may be stale but ensure
# immediate connectivity before any DNS queries go through dnsmasq)
for f in /etc/firewall-github-cidrs.txt \
         /etc/firewall-azure-storage-cidrs.txt \
         /etc/firewall-resolved-ips.txt; do
    while read -r cidr; do
        [ -n "$cidr" ] && ipset add allowed-domains "$cidr" 2>/dev/null || true
    done < "$f"
done

# Allow host/Docker bridge network
iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Default deny, then allow established + whitelisted
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configured. Verifying..."
if curl --connect-timeout 5 -sf https://example.com >/dev/null 2>&1; then
    echo "WARN: firewall check failed — example.com is reachable"
else
    echo "OK: example.com blocked as expected"
fi

# ---- Drop privileges and launch Claude ----
# We need a real interactive bash with an active prompt loop so that Ctrl-Z
# suspends Claude and drops to a shell (fg to resume).
#
# Why bash -c doesn't work (even with -i or set -m):
#   bash -c 'cmd' executes the command string and exits — there is no
#   read-eval-print loop. When the child is stopped by SIGTSTP, bash has
#   no prompt to return to, so it just exits (taking the container with it).
#
# Solution: start a real interactive bash via --rcfile. The rcfile uses
# PROMPT_COMMAND to launch Claude exactly once, at the first prompt —
# when job control is already active. Ctrl-Z then works normally:
# bash suspends Claude, shows its prompt, and fg resumes it.
shift  # consume the "--" separator

# Build the claude command with properly quoted args
CLAUDE_CMD="claude --dangerously-skip-permissions"
for arg in "$@"; do
    CLAUDE_CMD+=" $(printf '%q' "$arg")"
done

CLAUDE_RCFILE="/tmp/claude-bashrc"
cat > "$CLAUDE_RCFILE" <<RCEOF
# Source the default bashrc for colors, aliases, prompt, etc.
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f ~/.bashrc ] && . ~/.bashrc

# Launch Claude once at the first prompt (job control is active by then).
# After Claude exits normally, exit the shell too (stops the container).
# If Claude was suspended (Ctrl-Z), the prompt loop keeps running.
_launch_claude() {
    # Remove ourselves so we only fire once
    unset PROMPT_COMMAND
    $CLAUDE_CMD
    local rc=\$?
    # If there are stopped jobs (Ctrl-Z), stay in the shell
    if jobs -s | grep -q .; then
        echo "(Claude suspended — type 'fg' to resume, 'exit' to quit)"
        return
    fi
    exit "\$rc"
}
PROMPT_COMMAND=_launch_claude
RCEOF
chown claude:claude "$CLAUDE_RCFILE"

exec runuser -u claude -- bash --rcfile "$CLAUDE_RCFILE" -i
FWEOF

# ---------- pre-flight checks ----------

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed or not in PATH" >&2
    exit 1
fi

if [[ ! -x "$CLAUDE_BINARY" ]]; then
    echo "ERROR: claude binary not found at $CLAUDE_BINARY" >&2
    exit 1
fi

# ---------- build image if needed ----------

# Detect the GID of the host docker socket so the container user can access it
DOCKER_GID="$(stat -c '%g' "$DOCKER_SOCK" 2>/dev/null || echo 965)"

echo "Building Docker image '$BUILT_IMAGE'..."
echo "$DOCKERFILE" | docker build --build-arg "DOCKER_GID=$DOCKER_GID" -t "$BUILT_IMAGE" -

# ---------- optional mounts (skip if not present on host) ----------

OPTIONAL_MOUNTS=()

# Nix/Home Manager manages dotfiles as symlinks into /nix/store, which doesn't
# exist inside the container. For each directory we bind-mount, find symlinks
# whose targets fall outside that directory (i.e. would be broken in the
# container) and add individual file mounts with the resolved (dereferenced)
# target. Docker file mounts layer on top of directory mounts, so the resolved
# file is visible at the symlink's path inside the container.
resolve_external_symlinks() {
    local host_dir="${1%/}" container_dir="${2%/}" mode="$3"
    local real_host_dir
    real_host_dir="$(readlink -f "$host_dir")"
    while IFS= read -r -d '' link; do
        local target
        target="$(readlink -f "$link")"
        # Skip if the target is inside the same mount (it will resolve fine)
        [[ "$target" == "$real_host_dir"/* ]] && continue
        # Compute the relative path and map to the container mount point
        local rel="${link#"$host_dir"/}"
        OPTIONAL_MOUNTS+=(-v "${target}:${container_dir}/${rel}:${mode}")
    done < <(find "$host_dir" -maxdepth 2 -type l -print0 2>/dev/null)
}

add_mount() {
    local mode="$1" src="$2" dst="$3"
    # Resolve symlinks (e.g. Nix store symlinks) so the target exists in the
    # container even when the symlink's intermediate path doesn't.
    local resolved
    resolved="$(readlink -f "$src" 2>/dev/null)" || resolved="$src"
    if [[ -e "$resolved" ]]; then
        OPTIONAL_MOUNTS+=(-v "${resolved}:${dst}:${mode}")
        # For directories, resolve any symlinks that point outside the mount
        # (e.g. Nix store symlinks) so they're visible inside the container.
        if [[ -d "$resolved" ]]; then
            # Always ro: resolved targets are typically in /nix/store or
            # similar read-only locations and can't be mounted rw.
            resolve_external_symlinks "$src" "$dst" ro
        fi
    fi
}

# Claude config dir — needs rw because Claude writes session state, history,
# and .claude.json (auth/stats) inside this directory.
add_mount rw "${HOME}/.claude"      "/home/claude/.claude"
add_mount rw "${HOME}/.claude.json" "/home/claude/.claude.json"
# TODO: request a dedicated NUGET_TOKEN (packages-only, readonly) for use
# inside the container, rather than mounting the host NuGet config which may
# contain broader credentials.
# NuGet config files — symlinks are resolved by add_mount automatically.
add_mount ro "${HOME}/.config/NuGet/NuGet.Config" "/home/claude/.config/NuGet/NuGet.Config"
add_mount ro "${HOME}/.config/NuGet/config/rg.config" "/home/claude/.config/NuGet/config/rg.config"
add_mount rw "${HOME}/.nuget/packages" "/home/claude/.nuget/packages"
# Mount .dotfiles at both the container home and the host's absolute path.
# The container home mount is for convenience; the host path mount is needed
# because settings.json hooks contain hardcoded host paths (e.g.
# /home/nixos/.dotfiles/utils/...) that must resolve inside the container.
add_mount ro "${HOME}/.dotfiles"    "/home/claude/.dotfiles"
if [[ "${HOME}/.dotfiles" != "/home/claude/.dotfiles" ]]; then
    add_mount ro "${HOME}/.dotfiles" "${HOME}/.dotfiles"
fi
add_mount ro "${HOME}/.gitconfig"   "/home/claude/.gitconfig"
add_mount ro "${HOME}/.config/git/" "/home/claude/.config/git/"
add_mount ro "${HOME}/.config/gh"   "/home/claude/.config/gh"

# Docker socket — only mounted when --docker is passed
if [[ "$MOUNT_DOCKER" == true ]]; then
    if [[ -S "$DOCKER_SOCK" ]]; then
        OPTIONAL_MOUNTS+=(-v "${DOCKER_SOCK}:${DOCKER_SOCK}:rw")
    else
        echo "WARN: --docker requested but $DOCKER_SOCK not found, skipping" >&2
    fi
fi

# ---------- inject firewall script into /tmp so the container can run it ----------

FIREWALL_TMP="$(mktemp)"
echo "$FIREWALL_SCRIPT" > "$FIREWALL_TMP"
chmod +x "$FIREWALL_TMP"
trap 'rm -f "$FIREWALL_TMP"' EXIT

# ---------- run ----------

echo "Starting Claude Code in Docker (YOLO mode)..."
echo "  Working dir  : $HOST_PROJECT_DIR"
if [[ -n "$WORKTREE_NAME" ]]; then
echo "  Worktree     : $WORKTREE_NAME (branch from $(git -C "$HOST_REPO_DIR" rev-parse --short HEAD))"
echo "  Main repo    : $HOST_REPO_DIR (mounted ro)"
fi
echo "  Claude binary: $CLAUDE_BINARY"
echo "  Docker socket: $(if [[ "$MOUNT_DOCKER" == true ]]; then echo "mounted"; else echo "no (use --docker)"; fi)"
echo ""

# In worktree mode, mount both the worktree and the main repo at their host
# absolute paths so git's cross-references (worktree .git file → repo,
# repo gitdir backlink → worktree) resolve correctly. The repo is mounted
# read-only to prevent Claude from accidentally committing there.
# Without worktree mode, mount the project at /home/claude/project as before.
if [[ -n "$WORKTREE_NAME" ]]; then
    # The main repo must be rw because git shares its object store and refs
    # across all worktrees — git add/commit write to .git/objects/ and .git/refs/.
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
    \
    `# ---- [3] firewall: NET_ADMIN + NET_RAW let the container configure iptables ----` \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    \
    `# ---- RW mounts ----` \
    "${PROJECT_MOUNTS[@]}" \
    -v "/tmp/claude:/tmp/claude:rw" \
    -v "$FIREWALL_TMP:/usr/local/bin/init-firewall.sh:ro" \
    \
    `# ---- Conditional mounts ----` \
    "${OPTIONAL_MOUNTS[@]}" \
    \
    `# ---- Claude binary itself ----` \
    -v "$CLAUDE_BINARY:/usr/local/bin/claude:ro" \
    \
    `# ---- Environment ----` \
    -e "HOME=/home/claude" \
    -e "TERM=${TERM:-xterm-256color}" \
    `# [1] Prevents Node.js OOM on large sessions / big codebases` \
    -e "NODE_OPTIONS=--max-old-space-size=4096" \
    `# NuGet feed credentials — env var format avoids XML key name mismatch` \
    `# between packageSources and packageSourceCredentials configs.` \
    -e "NuGetPackageSourceCredentials_red_gate_vsts_main_v3=${NuGetPackageSourceCredentials_red_gate_vsts_main_v3:-}" \
    `# Docker host address — tests connect to Docker containers via host-mapped` \
    `# ports, which aren't reachable at localhost from inside a sibling container.` \
    `# The bridge gateway IP routes to the host's published ports.` \
    -e "DOCKER_HOST_ADDRESS=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')" \
    \
    `# ---- Network: bridge (default) so the firewall's iptables rules are` \
    `#        scoped to the container's own network namespace. Do NOT use`  \
    `#        --network host — that shares the host namespace, so the`      \
    `#        firewall rules would apply to (and persist on) the host. ----` \
    `# ---- DNS: route through local dnsmasq so it can auto-add resolved`  \
    `#        IPs to the firewall ipset. dnsmasq forwards to the host's`   \
    `#        upstream DNS. ----`                                           \
    --dns 127.0.0.1 \
    -e "HOST_DNS=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')" \
    \
    "$BUILT_IMAGE" \
    \
    /usr/local/bin/init-firewall.sh -- "${CLAUDE_ARGS[@]}"
