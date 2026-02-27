#!/usr/bin/env bash
set -euo pipefail

# Run Claude Code in YOLO mode (--dangerously-skip-permissions) inside a Docker container.
# This avoids sandbox issues by giving Claude full access inside the container,
# while the container itself provides isolation from the host.
#
# Usage: run-claude-docker.sh [--docker] [claude args...]
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

# ---------- parse options ----------

MOUNT_DOCKER=false
CLAUDE_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker) MOUNT_DOCKER=true; shift ;;
        *)        CLAUDE_ARGS+=("$1"); shift ;;
    esac
done

# ---------- configuration ----------

BUILT_IMAGE="claude-yolo"
CONTAINER_NAME="claude-yolo-$$"
DOCKER_SOCK="/var/run/docker.sock"

HOST_PROJECT_DIR="$PWD"
CLAUDE_BINARY="$(readlink -f ~/.local/bin/claude)"

# ---------- Dockerfile (inline) ----------
# Kept in a variable for readability; piped to `docker build` below.

read -r -d '' DOCKERFILE <<'EOF' || true
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

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
        iptables \
        ipset \
        iproute2 \
        dnsutils \
        aggregate \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI — only the client, no daemon. Talks to the host daemon via the
# bind-mounted socket. Needed for tests that spin up on-demand containers
# (e.g. test databases).
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

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

RUN apt-get update && apt-get install -y --no-install-recommends \
      default-jdk-headless \
      maven \
  && rm -rf /var/lib/apt/lists/*

# [5] Passwordless sudo for the claude user
RUN echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude && \
    chmod 0440 /etc/sudoers.d/claude

# NuGet reads config from ~/.nuget/NuGet/, which on the host is a symlink to
# ~/.config/NuGet/. Replicate that layout so bind-mounted configs at
# ~/.config/NuGet/ are found by NuGet at its expected path.
RUN mkdir -p /home/claude/.nuget /home/claude/.config/NuGet && \
    ln -s /home/claude/.config/NuGet /home/claude/.nuget/NuGet && \
    chown -R claude:claude /home/claude/.nuget /home/claude/.config/NuGet

# ---- Firewall: resolve IPs at build time and bake into the image ----
# This avoids slow DNS resolution and API fetches at container startup.
# IPs go stale as the image ages; rebuild with --no-cache to refresh.

# GitHub IP ranges
RUN curl -sf https://api.github.com/meta | \
    jq -r '(.web + .api + .git)[]' | aggregate -q \
    > /etc/firewall-github-cidrs.txt

# Azure Storage IP ranges for UK South (where Azure DevOps stores NuGet
# package blobs on *.blob.core.windows.net). Fetched from Microsoft's
# weekly-updated service tags JSON.
RUN DOWNLOAD_PAGE=$(curl -sf 'https://www.microsoft.com/en-us/download/details.aspx?id=56519') && \
    JSON_URL=$(echo "$DOWNLOAD_PAGE" | grep -oP 'https://download\.microsoft\.com/download/[^"]+\.json' | head -1) && \
    curl -sf "$JSON_URL" | \
    jq -r '.values[] | select(.name == "Storage") | .properties.addressPrefixes[]' | \
    grep -v ':' \
    > /etc/firewall-azure-storage-cidrs.txt

# Individual domains Claude needs — resolved to IPs
RUN for domain in \
        api.anthropic.com \
        statsig.anthropic.com \
        statsig.com \
        sentry.io \
        registry.npmjs.org \
        registry-1.docker.io \
        auth.docker.io \
        production.cloudflare.docker.com \
        archive.ubuntu.com \
        security.ubuntu.com \
        api.nuget.org \
        azureedge.net \
        dotnetcli.azureedge.net \
        repo1.maven.org \
        red-gate.pkgs.visualstudio.com; do \
    dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}'; \
    done | sort -u > /etc/firewall-resolved-ips.txt

USER claude
WORKDIR /home/claude/project
EOF

# ---------- firewall init script (inline) ----------
# [3] Loads the pre-resolved IP whitelist baked into the image at build time,
#     then configures iptables to default-deny all outbound traffic except
#     to those IPs (plus DNS, SSH, localhost, and the Docker bridge).
#     Requires --cap-add=NET_ADMIN and --cap-add=NET_RAW on docker run.

read -r -d '' FIREWALL_SCRIPT <<'FWEOF' || true
#!/bin/bash
set -euo pipefail

echo "Configuring firewall..."

HOST_IP=$(ip route | grep default | cut -d" " -f3)
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")

# Preserve Docker's internal DNS NAT rules before flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush everything
iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Restore Docker DNS if present
if [ -n "$DOCKER_DNS_RULES" ]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# Allow DNS, SSH, and localhost
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Build the whitelist ipset from pre-resolved data baked into the image
ipset create allowed-domains hash:net

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

add_mount() {
    local mode="$1" src="$2" dst="$3"
    if [[ -e "$src" ]]; then
        OPTIONAL_MOUNTS+=(-v "${src}:${dst}:${mode}")
    fi
}

# Claude config dir — needs rw because Claude writes session state, history,
# and .claude.json (auth/stats) inside this directory.
add_mount rw "${HOME}/.claude"      "/home/claude/.claude"
add_mount rw "${HOME}/.claude.json" "/home/claude/.claude.json"
# TODO: request a dedicated NUGET_TOKEN (packages-only, readonly) for use
# inside the container, rather than mounting the host NuGet config which may
# contain broader credentials.
# NuGet config files — mounted individually with symlinks resolved, because
# the host directory contains Nix store symlinks that don't exist in the container.
add_mount ro "$(readlink -f "${HOME}/.config/NuGet/NuGet.Config")" "/home/claude/.config/NuGet/NuGet.Config"
add_mount ro "$(readlink -f "${HOME}/.config/NuGet/config/rg.config")" "/home/claude/.config/NuGet/config/rg.config"
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
add_mount ro "${HOME}/.config/git/config" "/home/claude/.config/git/config"
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
echo "  Claude binary: $CLAUDE_BINARY"
echo "  Docker socket: $(if [[ "$MOUNT_DOCKER" == true ]]; then echo "mounted"; else echo "no (use --docker)"; fi)"
echo ""

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
    -v "$HOST_PROJECT_DIR:/home/claude/project:rw" \
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
    \
    "$BUILT_IMAGE" \
    \
    bash -c 'sudo /usr/local/bin/init-firewall.sh && exec claude --dangerously-skip-permissions "$@"' -- "${CLAUDE_ARGS[@]}"
