#!/usr/bin/env bash
set -euo pipefail

# Test wrapper for the agent sandbox network stack (Phase B.1: sidecar proxy).
#
# A sibling to run-claude-sandbox.sh — drives run-agent-sandbox.sh with a test
# harness as the "agent command" instead of a real agent. Exercises:
#
#   - L7 proxy policy: allowed hosts, blocked hosts, subdomain matching
#   - Sidecar enforcement: QUIC blocked, DoT blocked, raw TCP blocked
#   - Domain fronting rejection
#   - Proxy CA trust: curl/python/node don't need --insecure
#   - Sidecar isolation: proxy/policy unreachable from agent container
#   - iptables flush resilience: flushing agent's iptables has no effect
#   - Inner dockerd: nested containers work
#   - Network topology: agent on internal network, sidecar as sole gateway
#   - DNS: resolution works for both allowed and blocked domains
#
# Usage: test-sandbox-egress.sh [--no-docker]
#   --no-docker   Skip inner dockerd / nested container tests (faster).
#   Run from any directory.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- parse options ----------

SKIP_DOCKER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-docker) SKIP_DOCKER=1; shift ;;
        *) echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
    esac
done

# ---------- hand off to the generic core ----------
# The test harness script (egress-test-harness.sh) is bind-mounted into the
# container and run as the agent command. It runs as the claude user, which is
# exactly the threat model we're testing.

# Phase C: generate the same placeholder configs a real wrapper would.
PHASE_C_TMPDIR="$(mktemp -d)"
cleanup_test() { rm -rf "$PHASE_C_TMPDIR"; }
trap cleanup_test EXIT

mkdir -p "$PHASE_C_TMPDIR/gh"
cat > "$PHASE_C_TMPDIR/gh/hosts.yml" <<'GHEOF'
github.com:
    oauth_token: SANDBOX-PLACEHOLDER-GH-TOKEN
    user: sandbox-agent
    git_protocol: https
GHEOF

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

exec "$HERE/run-agent-sandbox.sh" \
    --agent-cmd "bash /opt/egress-test-harness.sh" \
    --mount "ro:$HERE/egress-test-harness.sh:/opt/egress-test-harness.sh" \
    --mount "ro:$PHASE_C_TMPDIR/gh:/home/claude/.config/gh" \
    --mount "ro:$PHASE_C_TMPDIR/git-credential-sandbox.sh:/opt/sandbox/git-credential-sandbox.sh" \
    --mount "ro:$PHASE_C_TMPDIR/gitconfig.d/sandbox-credentials.inc:/opt/sandbox/sandbox-credentials.inc" \
    --env "SKIP_DOCKER_TESTS=${SKIP_DOCKER:-}" \
    --env "CLAUDE_CODE_OAUTH_TOKEN=SANDBOX-PLACEHOLDER-CLAUDE-OAUTH" \
    -- # no extra agent args
