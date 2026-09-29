#!/usr/bin/env bash
set -euo pipefail

# List recently-blocked egress destinations for each running sandbox sidecar.
#
# Usage: sandbox-blocked-domains.sh [count]   (default 50 per sidecar)
#
# Sidecars are found by the agent-sandbox.instance label and described by the
# agent-sandbox.project / agent-sandbox.worktree labels set by the launcher.
# Output is most-recent first, deduplicated.

COUNT="${1:-50}"

mapfile -t SIDECARS < <(docker ps -q \
    -f label=agent-sandbox.instance \
    -f label=agent-sandbox.role=sidecar)

if [[ ${#SIDECARS[@]} -eq 0 ]]; then
    echo "No running sandbox sidecars." >&2
    exit 0
fi

for c in "${SIDECARS[@]}"; do
    desc="$(docker inspect -f '{{index .Config.Labels "agent-sandbox.project"}}|{{index .Config.Labels "agent-sandbox.worktree"}}|{{.Name}}' "$c")"
    IFS='|' read -r project worktree name <<<"$desc"
    header="${project:-unknown}"
    [[ -n "$worktree" ]] && header+=" @ $worktree"
    echo "=== $header (${name#/}) ==="

    # Log lines look like "[hh:mm:ss.mmm] BLOCKED (<reason>): <dest>...", so
    # field 4 is the destination.
    docker exec "$c" cat /var/log/mitmproxy.log 2>/dev/null \
        | grep 'BLOCKED' \
        | cut -d' ' -f4 \
        | tac \
        | awk '!seen[$0]++' \
        | head -n "$COUNT" \
        || true
    echo
done
