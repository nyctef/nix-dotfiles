# Agent image for the sysbox-based sandbox.
#
# KEY DIFFERENCE from the old run-claude-docker image: this image installs the
# full Docker *daemon* (docker-ce + containerd), not just the CLI. There is NO
# host Docker socket mount. The container runs under `--runtime=sysbox-runc`,
# so dockerd runs unprivileged-but-functional INSIDE the container via user
# namespaces. `dotnet test -> docker run -p 5432:5432` then works with native
# localhost/bind-mount ergonomics, and the test containers are nested children
# of the agent container, not host siblings.
#
# Phase A scope: ergonomics only. Network egress is NOT yet restricted in this
# image (that is Phase B: an in-container L7 proxy + mandatory iptables floor).
# Until then, treat the network as open.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Trust anchor for the HTTPS third-party repos added below.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates

# Docker repo (daemon + CLI this time).
ADD --chmod=0644 https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.asc
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list

# GitHub CLI repo (upstream gh; Ubuntu's is too old for `gh pr edit`).
ADD --chmod=0644 https://cli.github.com/packages/githubcli-archive-keyring.gpg /etc/apt/keyrings/githubcli.gpg
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] \
      https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list

# Microsoft repo (PowerShell). Register key+list by hand; the prod .deb depends
# on ca-certificates and dpkg rejects installing it standalone.
ADD --chmod=0644 https://packages.microsoft.com/keys/microsoft.asc /etc/apt/keyrings/microsoft.asc
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.asc] \
      https://packages.microsoft.com/ubuntu/24.04/prod $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
      > /etc/apt/sources.list.d/microsoft-prod.list

# One big install. NOTE vs old image:
#   + docker-ce, containerd.io  -> the inner daemon (was: docker-ce-cli only)
#   - dnsmasq/ipset/aggregate   -> dropped; Phase B replaces the L3/L4 ipset
#                                  firewall with an L7 proxy. iptables kept as
#                                  the future mandatory floor.
# apt lists are intentionally left in place so the agent can install extras at
# runtime without a re-fetch.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        gh \
        jq \
        less \
        python3 python-is-python3 \
        procps \
        sudo \
        iptables \
        iproute2 \
        dnsutils \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin \
        default-jdk-headless \
        maven \
        powershell

# Non-root user matching the host UID (1000). Ubuntu 24.04 ships a 'ubuntu'
# user at 1000; remove it so we can take that UID. Add claude to the docker
# group so it can talk to the inner daemon's socket without sudo.
RUN userdel -r ubuntu 2>/dev/null || true && \
    groupadd -f -g 1000 claude && \
    useradd -m -u 1000 -g claude -s /bin/bash claude && \
    (groupadd -f docker || true) && \
    usermod -aG docker claude

# .NET SDK — pinned to the host's version via build arg (also busts cache on
# host upgrade).
ARG DOTNET_SDK_VERSION
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    bash /tmp/dotnet-install.sh --version "${DOTNET_SDK_VERSION}" --install-dir /usr/share/dotnet && \
    ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet && \
    rm /tmp/dotnet-install.sh
ENV DOTNET_ROOT=/usr/share/dotnet

# Flyway CLI — pinned to the host's version via build arg.
ARG FLYWAY_VERSION
RUN curl -fsSL "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/${FLYWAY_VERSION}/flyway-commandline-${FLYWAY_VERSION}-linux-x64.tar.gz" \
        -o /tmp/flyway.tar.gz && \
    mkdir -p /usr/share/flyway && \
    tar -xzf /tmp/flyway.tar.gz -C /usr/share/flyway --strip-components=1 && \
    chmod -R a+rX /usr/share/flyway && \
    chmod a+x /usr/share/flyway/flyway /usr/share/flyway/jre/bin/* && \
    ln -s /usr/share/flyway/flyway /usr/local/bin/flyway && \
    rm /tmp/flyway.tar.gz

# Jujutsu (jj).
RUN JJ_VERSION="0.40.0" && \
    curl -fsSL "https://github.com/jj-vcs/jj/releases/download/v${JJ_VERSION}/jj-v${JJ_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/jj.tar.gz && \
    tar -xzf /tmp/jj.tar.gz -C /usr/local/bin ./jj && \
    chmod +x /usr/local/bin/jj && \
    rm /tmp/jj.tar.gz

# Sudo for claude — package management only (so the agent can apt-get extras).
# NOTE: dockerd is started by the entrypoint as root before privileges drop, so
# the agent does not need sudo for docker. Phase B will add the firewall here
# and must NOT be in claude's sudoers.
RUN echo "claude ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg" \
    > /etc/sudoers.d/claude && \
    chmod 0440 /etc/sudoers.d/claude

# NuGet config layout: ~/.nuget/NuGet -> ~/.config/NuGet so bind-mounted
# configs are found at NuGet's expected path.
RUN mkdir -p /home/claude/.nuget /home/claude/.config/NuGet /home/claude/.local && \
    ln -s /home/claude/.config/NuGet /home/claude/.nuget/NuGet && \
    chown -R claude:claude /home/claude/.nuget /home/claude/.config /home/claude/.local

# Entrypoint: starts the inner dockerd, then drops to the claude user and
# launches Claude via the interactive-rcfile trick (Ctrl-Z support).
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /home/claude/project
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
