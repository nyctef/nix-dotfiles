#!/usr/bin/env bash
set -euo pipefail

# In-container entrypoint for the sysbox sandbox.
#
# Runs as root (container UID 0, which sysbox remaps to an unprivileged host
# subuid). Startup sequence is ordered to close the root-escalation gap:
#
#   1. Start the egress proxy + install the MITM CA (before dockerd!)
#   2. Start the inner Docker daemon (picks up MITM CA from system store)
#   3. Activate the iptables firewall (ALL uids go through the proxy)
#   4. Drop to the unprivileged `claude` user and launch the agent
#
# This ordering ensures that even if the agent escalates to root (via docker
# group membership or sudo), root traffic goes through the L7 proxy.
#
# Args: everything after `--` is forwarded to the agent.

FIREWALL_SCRIPT="/usr/local/bin/init-egress-firewall.sh"
FIREWALL_DISABLED="${SANDBOX_DISABLE_FIREWALL:-}"

# ---------- 1. start egress proxy + install CA ----------
# Must happen BEFORE dockerd so dockerd trusts the MITM CA from its very
# first registry connection (Go's crypto/x509 reads the system cert bundle
# per-connection, not cached at process start).

if [[ "$FIREWALL_DISABLED" == "1" ]]; then
    echo "WARN: egress firewall disabled (SANDBOX_DISABLE_FIREWALL=1)." >&2
else
    "$FIREWALL_SCRIPT" start-proxy
fi

# ---------- 2. start inner dockerd ----------

echo "Starting inner Docker daemon (nested, via sysbox)..."

# /var/lib/docker is a per-instance volume mounted by the launcher so parallel
# agents never share a data-root.
dockerd >/var/log/dockerd.log 2>&1 &
DOCKERD_PID=$!

# Wait for the daemon socket to come up.
for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
        echo "Inner dockerd ready."
        break
    fi
    if ! kill -0 "$DOCKERD_PID" 2>/dev/null; then
        echo "ERROR: inner dockerd exited during startup. Log tail:" >&2
        tail -n 40 /var/log/dockerd.log >&2 || true
        exit 1
    fi
    sleep 1
done

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: inner dockerd did not become ready within 30s. Log tail:" >&2
    tail -n 40 /var/log/dockerd.log >&2 || true
    exit 1
fi

# ---------- 3. activate iptables firewall ----------
# Now that dockerd is up and trusts the CA, activate the iptables rules that
# redirect ALL traffic (including root) through the proxy.

if [[ "$FIREWALL_DISABLED" != "1" ]]; then
    "$FIREWALL_SCRIPT" start-firewall
fi

# ---------- 4. drop privileges and launch the agent ----------
# See run-claude-docker.sh for the full explanation of why `bash -c` can't
# support Ctrl-Z and the rcfile/PROMPT_COMMAND trick is needed.

AGENT_CMD="${SANDBOX_AGENT_CMD:?SANDBOX_AGENT_CMD not set by the launcher}"

shift  # consume the "--" separator
for arg in "$@"; do
    AGENT_CMD+=" $(printf '%q' "$arg")"
done

AGENT_RCFILE="/tmp/agent-bashrc"
cat > "$AGENT_RCFILE" <<RCEOF
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f ~/.bashrc ] && . ~/.bashrc
[ -f /etc/profile.d/proxy-ca.sh ] && . /etc/profile.d/proxy-ca.sh

_launch_agent() {
    unset PROMPT_COMMAND
    $AGENT_CMD
    local rc=\$?
    if jobs -s | grep -q .; then
        echo "(agent suspended — type 'fg' to resume, 'exit' to quit)"
        return
    fi
    exit "\$rc"
}
PROMPT_COMMAND=_launch_agent
RCEOF
chown claude:claude "$AGENT_RCFILE"

export PATH=$PATH:/home/claude/.local/bin

# Source the proxy CA env vars so the agent's tools trust the MITM cert.
[[ -f /etc/profile.d/proxy-ca.sh ]] && . /etc/profile.d/proxy-ca.sh

exec runuser -u claude -- bash --rcfile "$AGENT_RCFILE" -i
