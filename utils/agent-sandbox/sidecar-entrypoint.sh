#!/usr/bin/env bash
set -euo pipefail

# Sidecar proxy entrypoint (Phase B.1).
#
# Runs mitmproxy in transparent mode, configures iptables to redirect
# HTTP(S) from the internal interface to the proxy, enables IP forwarding
# for DNS, and blocks all non-HTTP forwarding.
#
# Network topology:
#   - eth_external (default bridge): internet access, has the default route
#   - eth_internal (sandbox-internal): agent-facing, no internet route
#
# Traffic flow:
#   agent → sidecar internal IF → PREROUTING REDIRECT → mitmproxy (local)
#   mitmproxy → sidecar external IF → internet
#   non-HTTP from agent → sidecar FORWARD → REJECT

PROXY_PORT=8080
PROXY_CONFDIR="/etc/mitmproxy"
CA_SHARE_DIR="/shared-ca"
PROXY_LOGFILE="/var/log/mitmproxy.log"

# ── 1. Start mitmproxy ──────────────────────────────────────────────────────

mkdir -p "$PROXY_CONFDIR" "$CA_SHARE_DIR"

echo "Starting egress proxy (mitmproxy transparent, port $PROXY_PORT)..."
mitmdump \
    --mode transparent \
    --listen-port "$PROXY_PORT" \
    --set confdir="$PROXY_CONFDIR" \
    --set connection_strategy=lazy \
    --ssl-insecure \
    -s /opt/egress-policy.py \
    >"$PROXY_LOGFILE" 2>&1 &
PROXY_PID=$!

# Wait for CA generation
echo "Waiting for proxy CA certificate..."
for _ in $(seq 1 30); do
    if [[ -f "$PROXY_CONFDIR/mitmproxy-ca-cert.pem" ]]; then
        break
    fi
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "ERROR: egress proxy exited during startup. Log:" >&2
        cat "$PROXY_LOGFILE" >&2 || true
        exit 1
    fi
    sleep 0.5
done

if [[ ! -f "$PROXY_CONFDIR/mitmproxy-ca-cert.pem" ]]; then
    echo "ERROR: proxy CA cert not generated within 15s." >&2
    tail -n 30 "$PROXY_LOGFILE" >&2 || true
    exit 1
fi

# Share CA with agent container via Docker volume
cp "$PROXY_CONFDIR/mitmproxy-ca-cert.pem" "$CA_SHARE_DIR/mitmproxy-ca-cert.pem"
echo "CA certificate shared at $CA_SHARE_DIR/mitmproxy-ca-cert.pem"

# ── 2. Identify network interfaces ──────────────────────────────────────────

# External interface: has the default route (bridge → internet)
EXTERNAL_IF=$(ip route | grep default | awk '{print $5}' | head -1)

# Internal interface: any non-lo, non-external UP interface.
# The internal network may be connected after startup (docker network connect),
# so wait for it to appear. Strip the @ifN suffix from veth names.
echo "Waiting for internal network interface..."
INTERNAL_IF=""
for _ in $(seq 1 30); do
    INTERNAL_IF=$(ip -o link show up | awk -F'[: ]+' '{print $2}' \
        | sed 's/@.*//' | grep -v lo | grep -v "$EXTERNAL_IF" | head -1)
    [[ -n "$INTERNAL_IF" ]] && break
    sleep 0.5
done

if [[ -z "$EXTERNAL_IF" || -z "$INTERNAL_IF" ]]; then
    echo "ERROR: could not identify network interfaces." >&2
    echo "  External (default route): ${EXTERNAL_IF:-<not found>}" >&2
    echo "  Internal: ${INTERNAL_IF:-<not found>}" >&2
    echo "Links:" >&2; ip -o link show >&2
    echo "Routes:" >&2; ip route >&2
    exit 1
fi

echo "Network interfaces: external=$EXTERNAL_IF, internal=$INTERNAL_IF"

# ── 3. Configure iptables ───────────────────────────────────────────────────

# Enable IP forwarding (needed for DNS forwarding from agent).
# Try multiple methods: sysctl, procfs write, nft. NET_ADMIN capability is
# required but /proc/sys may be mounted read-only.
if sysctl -w net.ipv4.ip_forward=1 2>/dev/null; then
    echo "ip_forward enabled via sysctl"
elif echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; then
    echo "ip_forward enabled via procfs"
else
    echo "WARN: could not enable ip_forward — DNS forwarding may not work" >&2
fi

# NAT: masquerade traffic leaving via the external interface (mitmproxy's
# outbound connections to real servers)
iptables -t nat -A POSTROUTING -o "$EXTERNAL_IF" -j MASQUERADE

# DNS forwarding: the agent container uses the sidecar as its DNS server
# (Docker's embedded DNS can't resolve on --internal networks). Forward DNS
# queries arriving on the internal interface to the upstream resolver, which
# the sidecar can reach via its external interface.
#
# UPSTREAM_DNS is the real host DNS, passed from the launcher. We cannot use
# Docker's embedded DNS (127.0.0.11) as the DNAT target because the kernel
# won't route packets with external source IPs to the loopback interface.
UPSTREAM_DNS="${UPSTREAM_DNS:-}"
if [[ -z "$UPSTREAM_DNS" ]]; then
    # Fallback: try to parse the real DNS from Docker's resolv.conf comments
    UPSTREAM_DNS=$(grep -oP '(?<=host\()\d+\.\d+\.\d+\.\d+' /etc/resolv.conf | head -1) || true
fi
if [[ -z "$UPSTREAM_DNS" ]]; then
    echo "ERROR: no upstream DNS configured. Set UPSTREAM_DNS env var." >&2
    exit 1
fi
echo "Upstream DNS: $UPSTREAM_DNS"

# DNAT DNS to upstream (agent sends to sidecar IP:53, we forward to real DNS)
iptables -t nat -A PREROUTING -i "$INTERNAL_IF" -p udp --dport 53 \
    -j DNAT --to-destination "$UPSTREAM_DNS:53"
iptables -t nat -A PREROUTING -i "$INTERNAL_IF" -p tcp --dport 53 \
    -j DNAT --to-destination "$UPSTREAM_DNS:53"

# Transparent redirect: HTTP(S) arriving from internal network → mitmproxy.
# REDIRECT changes the destination to the local machine (sidecar):PROXY_PORT,
# so the traffic goes to INPUT (local mitmproxy), not FORWARD.
# mitmproxy reads SO_ORIGINAL_DST to learn the real destination.
iptables -t nat -A PREROUTING -i "$INTERNAL_IF" -p tcp --dport 80 \
    -j REDIRECT --to-port "$PROXY_PORT"
iptables -t nat -A PREROUTING -i "$INTERNAL_IF" -p tcp --dport 443 \
    -j REDIRECT --to-port "$PROXY_PORT"

# FORWARD chain: allow DNS (DNAT'd to upstream), block everything else.
# HTTP(S) is already redirected to local mitmproxy (INPUT), so legitimate web
# traffic never hits FORWARD. Only non-HTTP (raw TCP, QUIC, etc.) and DNS do.
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -j REJECT --reject-with icmp-admin-prohibited

# Block QUIC (UDP 443) and DoT (TCP 853) from the internal network
iptables -A INPUT -i "$INTERNAL_IF" -p udp --dport 443 \
    -j REJECT --reject-with icmp-admin-prohibited
iptables -A INPUT -i "$INTERNAL_IF" -p tcp --dport 853 \
    -j REJECT --reject-with tcp-reset

echo "Sidecar iptables configured."
echo "  HTTP(S) from $INTERNAL_IF → mitmproxy (port $PROXY_PORT)"
echo "  DNS forwarding: allowed"
echo "  QUIC (UDP 443), DoT (TCP 853): blocked"
echo "  All other forwarding: blocked"

# Signal readiness (agent entrypoint waits on this)
touch "$CA_SHARE_DIR/.sidecar-ready"

echo ""
echo "Sidecar proxy ready."

# ── 4. Keep running ─────────────────────────────────────────────────────────

wait "$PROXY_PID"
