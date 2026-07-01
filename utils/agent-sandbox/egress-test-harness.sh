#!/usr/bin/env bash
# In-container test harness for the sandbox network stack (Phase B.1: sidecar).
#
# Runs as the `claude` user (the "adversary" in our threat model). Tests the
# full Phase B.1 egress policy: forward proxy on --internal Docker network,
# L7 hostname allowlist, CA trust, sidecar isolation, and inner dockerd.
#
# Phase B.1 architecture:
#   - Agent on Docker --internal network (host-level iptables block external IPs)
#   - Sidecar proxy on both internal + bridge (internet)
#   - Agent uses HTTP_PROXY / HTTPS_PROXY to route through sidecar
#   - Even if agent ignores proxy env vars, --internal blocks direct connections
#   - Proxy process/policy/allowlist in sidecar → agent can't see/kill/modify
#
# Exit code: number of failed tests (0 = all passed).

set -uo pipefail

# ── colour / output helpers ──────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { ((PASS_COUNT++)); echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { ((FAIL_COUNT++)); echo -e "  ${RED}✗${RESET} $1"; }
skip() { ((SKIP_COUNT++)); echo -e "  ${YELLOW}⊘${RESET} $1 ${YELLOW}(skipped)${RESET}"; }
section() { echo -e "\n${BOLD}${CYAN}── $1 ──${RESET}"; }

# ── helpers ──────────────────────────────────────────────────────────────────

# Expect curl to connect to an allowed host via the proxy.
expect_allowed() {
    local label="$1" url="$2"; shift 2
    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 10 "$@" "$url" 2>/dev/null)" || true
    if [[ "$http_code" =~ ^[0-9]+$ && "$http_code" -gt 0 && "$http_code" -ne 403 ]]; then
        pass "$label (HTTP $http_code)"
    elif [[ "$http_code" == "403" ]]; then
        fail "$label (HTTP 403 — proxy blocked it)"
    else
        fail "$label (connection failed, http_code=$http_code)"
    fi
}

# Expect curl to fail for a blocked host.
expect_blocked() {
    local label="$1" url="$2"; shift 2
    local body status
    body="$(curl -sf --connect-timeout 5 --max-time 10 "$@" "$url" 2>&1)" && status=0 || status=$?
    if [[ $status -ne 0 ]]; then
        pass "$label"
    else
        fail "$label (expected block, but curl succeeded)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${BOLD}Agent Sandbox Network Test Harness (Phase B.1: Forward Proxy + --internal)${RESET}"
echo "Running as: $(whoami) (uid=$(id -u))"
echo "Date:       $(date -Iseconds)"
echo "HTTP_PROXY: ${HTTP_PROXY:-<not set>}"
echo "HTTPS_PROXY: ${HTTPS_PROXY:-<not set>}"
echo ""

# ── 1. Allowed HTTPS hosts (via proxy) ───────────────────────────────────────

section "Allowed HTTPS hosts (should succeed via proxy)"

expect_allowed "api.github.com (REST)" \
    "https://api.github.com/zen"

expect_allowed "github.com (HTML)" \
    "https://github.com/robots.txt"

expect_allowed "api.nuget.org (package registry)" \
    "https://api.nuget.org/v3/index.json"

expect_allowed "registry.npmjs.org (npm)" \
    "https://registry.npmjs.org/"

expect_allowed "pypi.org (Python)" \
    "https://pypi.org/simple/"

expect_allowed "repo1.maven.org (Maven)" \
    "https://repo1.maven.org/maven2/"

# ── 2. Allowed HTTPS subdomains ──────────────────────────────────────────────

section "Subdomain matching (subdomains of allowed domains)"

expect_allowed "objects.githubusercontent.com (GitHub subdomain)" \
    "https://objects.githubusercontent.com/"

expect_allowed "raw.githubusercontent.com (GitHub subdomain)" \
    "https://raw.githubusercontent.com/"

# ── 3. Blocked HTTPS hosts ──────────────────────────────────────────────────

section "Blocked HTTPS hosts (should fail with 403 or connection error)"

expect_blocked "example.com (not in allowlist)" \
    "https://example.com"

expect_blocked "evil.com (not in allowlist)" \
    "https://evil.com"

expect_blocked "httpbin.org (not in allowlist)" \
    "https://httpbin.org/get"

expect_blocked "ifconfig.me (potential exfil)" \
    "https://ifconfig.me"

expect_blocked "pastebin.com (potential exfil)" \
    "https://pastebin.com"

expect_blocked "webhook.site (potential C2)" \
    "https://webhook.site"

# ── 4. Blocked HTTP (plaintext, port 80) ────────────────────────────────────

section "Blocked HTTP (plaintext, port 80)"

expect_blocked "http://example.com (HTTP, not in allowlist)" \
    "http://example.com"

expect_blocked "http://httpbin.org/get (HTTP, not in allowlist)" \
    "http://httpbin.org/get"

# ── 5. Allowed HTTP (plaintext, port 80) ────────────────────────────────────

section "Allowed HTTP (plaintext, port 80)"

expect_allowed "http://archive.ubuntu.com (apt mirror)" \
    "http://archive.ubuntu.com/ubuntu/dists/noble/Release.gpg"

# ── 6. --internal network enforcement (mandatory, not cooperative) ──────────

section "Direct connections bypass proxy → blocked by --internal network"

# THE KEY TEST: even ignoring HTTP_PROXY, the agent can't reach external IPs.
# Docker's --internal host-level iptables DROP packets with non-subnet dests.

# Try to connect directly (bypassing proxy) using --noproxy
expect_blocked "direct HTTPS to example.com (--noproxy, blocked by --internal)" \
    "https://example.com" --noproxy '*'

expect_blocked "direct HTTPS to api.github.com (--noproxy, blocked by --internal)" \
    "https://api.github.com/zen" --noproxy '*'

# Raw TCP to external IP — also blocked by --internal
if timeout 3 bash -c 'echo >/dev/tcp/8.8.8.8/53' 2>/dev/null; then
    fail "raw TCP to 8.8.8.8:53 succeeded (--internal bypass!)"
else
    pass "raw TCP to 8.8.8.8:53 blocked (--internal enforcement)"
fi

if timeout 3 bash -c 'echo >/dev/tcp/1.1.1.1/443' 2>/dev/null; then
    fail "raw TCP to 1.1.1.1:443 succeeded (--internal bypass!)"
else
    pass "raw TCP to 1.1.1.1:443 blocked (--internal enforcement)"
fi

# ── 7. Raw TCP to non-HTTP ports (blocked by --internal) ────────────────────

section "Raw TCP to non-HTTP ports (blocked by --internal)"

if command -v nc &>/dev/null; then
    if nc -z -w 3 github.com 22 2>/dev/null; then
        fail "TCP 22 (SSH) to github.com is open"
    else
        pass "TCP 22 (SSH) to github.com blocked"
    fi
else
    if timeout 3 bash -c 'echo >/dev/tcp/github.com/22' 2>/dev/null; then
        fail "TCP 22 (SSH) to github.com is open"
    else
        pass "TCP 22 (SSH) to github.com blocked"
    fi
fi

if timeout 3 bash -c 'echo >/dev/tcp/smtp.gmail.com/25' 2>/dev/null; then
    fail "TCP 25 (SMTP) is open"
else
    pass "TCP 25 (SMTP) blocked"
fi

# ── 8. Proxy CA trust ───────────────────────────────────────────────────────

section "Proxy CA trust (TLS should work without --insecure)"

if curl -sf --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    pass "curl trusts proxy CA (no --insecure needed)"
else
    if curl -sf --insecure --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
        fail "curl doesn't trust proxy CA (works with --insecure)"
    else
        fail "curl can't reach api.github.com at all"
    fi
fi

if command -v python3 &>/dev/null; then
    if python3 -c "
import urllib.request, ssl, os
# Ensure proxy env is set for urllib
proxy_handler = urllib.request.ProxyHandler({
    'https': os.environ.get('HTTPS_PROXY', ''),
    'http': os.environ.get('HTTP_PROXY', ''),
})
opener = urllib.request.build_opener(proxy_handler)
ctx = ssl.create_default_context()
opener.open(urllib.request.Request('https://api.github.com/zen'), timeout=10)
" 2>/dev/null; then
        pass "python3 urllib trusts proxy CA (via proxy)"
    else
        fail "python3 urllib doesn't trust proxy CA"
    fi
else
    skip "python3 urllib CA trust — python3 not available"
fi

# Check env vars are set
if [[ -n "${SSL_CERT_FILE:-}" ]]; then
    pass "SSL_CERT_FILE is set ($SSL_CERT_FILE)"
else
    fail "SSL_CERT_FILE not set"
fi

if [[ -n "${NODE_EXTRA_CA_CERTS:-}" ]]; then
    pass "NODE_EXTRA_CA_CERTS is set ($NODE_EXTRA_CA_CERTS)"
else
    fail "NODE_EXTRA_CA_CERTS not set"
fi

if [[ -n "${HTTP_PROXY:-}" ]]; then
    pass "HTTP_PROXY is set ($HTTP_PROXY)"
else
    fail "HTTP_PROXY not set"
fi

if [[ -n "${HTTPS_PROXY:-}" ]]; then
    pass "HTTPS_PROXY is set ($HTTPS_PROXY)"
else
    fail "HTTPS_PROXY not set"
fi

# ── 9. Privilege separation (sidecar isolation) ─────────────────────────────

section "Privilege separation (sidecar proxy is unreachable)"

PROXY_PID="$(pgrep -f mitmdump 2>/dev/null | head -1)" || true
if [[ -n "$PROXY_PID" ]]; then
    fail "mitmdump process visible in agent container (should be in sidecar only)"
else
    pass "mitmdump process not visible (running in sidecar container)"
fi

if [[ -f /etc/firewall-domains.txt ]]; then
    fail "/etc/firewall-domains.txt exists in agent container"
else
    pass "/etc/firewall-domains.txt not present (in sidecar only)"
fi

if [[ -f /opt/egress-policy.py ]]; then
    fail "/opt/egress-policy.py exists in agent container"
else
    pass "/opt/egress-policy.py not present (in sidecar only)"
fi

# sudo restrictions
if sudo -n dpkg --version 2>/dev/null; then
    fail "claude can sudo dpkg"
else
    pass "sudo dpkg denied for claude user"
fi

if sudo -n apt-get --version >/dev/null 2>&1; then
    pass "sudo apt-get allowed (expected)"
else
    fail "sudo apt-get denied (agent needs this)"
fi

if sudo -n bash -c 'whoami' 2>/dev/null | grep -q root; then
    fail "claude can sudo to root shell (CRITICAL)"
else
    pass "sudo root shell denied for claude user"
fi

# ── 10. Root escalation via nested container ────────────────────────────────

section "Root escalation (gaining root must not bypass sidecar)"

if docker run --rm alpine sh -c \
    'apk add --no-cache curl >/dev/null 2>&1 && curl -sf --connect-timeout 5 https://example.com' \
    >/dev/null 2>&1; then
    fail "nested root container reached blocked host (bypass!)"
else
    pass "nested root container blocked from example.com"
fi

if docker run --rm --user root alpine sh -c \
    'apk add --no-cache curl >/dev/null 2>&1 && curl -sf --connect-timeout 5 https://example.com' \
    >/dev/null 2>&1; then
    fail "nested --user root container reached blocked host"
else
    pass "nested --user root container blocked from example.com"
fi

# ── 11. Domain fronting (Host ≠ SNI) ────────────────────────────────────────

section "Domain fronting detection (Host header ≠ SNI)"

# In forward proxy mode, we can test domain fronting via --connect-to:
# connect to github.com but send Host: evil.com
GITHUB_IP="$(dig +short +timeout=3 github.com A 2>/dev/null | head -1)" || true
if [[ -n "$GITHUB_IP" && "$GITHUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if curl -sf --connect-timeout 5 --max-time 10 \
        --resolve "evil.com:443:$GITHUB_IP" \
        "https://evil.com/" >/dev/null 2>&1; then
        fail "evil.com via github.com's IP succeeded (should be blocked)"
    else
        pass "evil.com via github.com's IP blocked (L7 hostname check)"
    fi
else
    # DNS may not work on --internal (no upstream resolver). This is fine —
    # the proxy handles DNS. Domain fronting is still tested via the proxy's
    # hostname check on the CONNECT request.
    skip "domain fronting — DNS not available on --internal network"
fi

# ── 12. Inner Docker (sysbox nested containers) ─────────────────────────────

section "Inner Docker (sysbox nested containers)"

if [[ "${SKIP_DOCKER_TESTS:-}" == "1" ]]; then
    skip "docker tests (--no-docker flag)"
else
    if docker info >/dev/null 2>&1; then
        pass "inner dockerd is running"
    else
        fail "inner dockerd not reachable"
    fi

    # docker pull goes through the inner dockerd, which uses HTTP_PROXY to
    # reach the registry via the sidecar proxy.
    if docker run --rm hello-world >/dev/null 2>&1; then
        pass "docker run hello-world succeeded (dockerd pulls through proxy)"
    else
        fail "docker run hello-world failed (dockerd can't pull through proxy?)"
    fi
fi

# ── 13. Network topology verification ───────────────────────────────────────

section "Network topology (--internal network)"

# On --internal networks, there should be no default route to the internet.
# The agent can only reach the sidecar's internal IP.
DEFAULT_GW="$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -1)" || true
if [[ -z "$DEFAULT_GW" ]]; then
    pass "no default route (--internal network, expected)"
elif [[ "$DEFAULT_GW" == "172.30.0.1" ]]; then
    # Docker assigns a gateway but --internal blocks it at host iptables
    pass "default route via bridge gateway (blocked by --internal host iptables)"
else
    fail "unexpected default route via $DEFAULT_GW"
fi

# ── 14. Diagnostics ─────────────────────────────────────────────────────────

section "Diagnostics"

if [[ -f /shared-ca/mitmproxy-ca-cert.pem ]]; then
    pass "sidecar CA cert present at /shared-ca/"
    if (echo "test" >> /shared-ca/mitmproxy-ca-cert.pem) 2>/dev/null; then
        fail "CA volume is writable (should be read-only)"
    else
        pass "CA volume is read-only"
    fi
else
    fail "sidecar CA cert not found at /shared-ca/"
fi

echo ""
echo "  Route table:"
ip route 2>/dev/null | sed 's/^/    /' || true
echo "  Proxy: ${HTTP_PROXY:-<not set>}"

# ── 15. Credential injection (Phase C) ────────────────────────────────────────────

section "Credential injection (Phase C: placeholder → real cred swap)"

# Verify placeholder env vars are present (not real creds).
if [[ "${ANTHROPIC_API_KEY:-}" == "SANDBOX-PLACEHOLDER-ANTHROPIC-KEY" ]]; then
    pass "ANTHROPIC_API_KEY is placeholder (not real key)"
elif [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    skip "ANTHROPIC_API_KEY not set (test not applicable)"
else
    fail "ANTHROPIC_API_KEY is NOT a placeholder (real key leaked to agent!)"
fi

# Verify real credentials are NOT in the agent's environment.
if env | grep -q 'SANDBOX_CRED_'; then
    fail "SANDBOX_CRED_* env vars found in agent container (should be sidecar only!)"
else
    pass "No SANDBOX_CRED_* env vars in agent container (sidecar only)"
fi

# Test that the credential helper script exists and is executable.
if [[ -x /opt/sandbox/git-credential-sandbox.sh ]]; then
    pass "git credential helper present at /opt/sandbox/"
else
    skip "git credential helper not mounted (no --mount for it)"
fi

# Test that the git config overlay exists.
if [[ -f /opt/sandbox/sandbox-credentials.inc ]]; then
    pass "git config overlay present at /opt/sandbox/"
else
    skip "git config overlay not mounted"
fi

# Test the credential helper returns placeholder tokens.
if [[ -x /opt/sandbox/git-credential-sandbox.sh ]]; then
    CRED_OUTPUT="$(echo -e 'protocol=https\nhost=github.com\n' | /opt/sandbox/git-credential-sandbox.sh 2>/dev/null)"
    if echo "$CRED_OUTPUT" | grep -q 'SANDBOX-PLACEHOLDER-GH-TOKEN'; then
        pass "credential helper returns placeholder for github.com"
    else
        fail "credential helper did not return placeholder (got: $CRED_OUTPUT)"
    fi
fi

# Test GitHub API with placeholder token → proxy should inject real token.
# This only works if the sidecar has SANDBOX_CRED_GITHUB_TOKEN set.
if [[ -n "${HTTP_PROXY:-}" ]]; then
    GH_RESPONSE="$(curl -sf --connect-timeout 5 --max-time 10 \
        -H 'Authorization: token SANDBOX-PLACEHOLDER-GH-TOKEN' \
        'https://api.github.com/user' 2>/dev/null)" && GH_STATUS=0 || GH_STATUS=$?
    if [[ $GH_STATUS -eq 0 ]] && echo "$GH_RESPONSE" | jq -e '.login' >/dev/null 2>&1; then
        GH_LOGIN="$(echo "$GH_RESPONSE" | jq -r '.login')"
        pass "GitHub API: placeholder swapped for real token (user: $GH_LOGIN)"
    elif [[ $GH_STATUS -eq 0 ]]; then
        # Got a response but not a valid user — maybe rate limited or bad token.
        fail "GitHub API: response received but no .login (placeholder not swapped?)"
    else
        skip "GitHub API: request failed (sidecar may not have SANDBOX_CRED_GITHUB_TOKEN)"
    fi
else
    skip "GitHub API credential test (no proxy configured)"
fi

# Test that gh CLI works with the placeholder config.
if command -v gh &>/dev/null && [[ -f /home/claude/.config/gh/hosts.yml ]]; then
    GH_CLI_OUTPUT="$(gh auth status 2>&1)" && GH_CLI_STATUS=0 || GH_CLI_STATUS=$?
    if echo "$GH_CLI_OUTPUT" | grep -qi 'logged in'; then
        pass "gh CLI: auth status reports logged in (placeholder config works)"
    else
        skip "gh CLI: auth status did not report logged in (may need real token in sidecar)"
    fi
else
    skip "gh CLI credential test (gh not available or no config)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Results: ${GREEN}${PASS_COUNT} passed${RESET}  ${RED}${FAIL_COUNT} failed${RESET}  ${YELLOW}${SKIP_COUNT} skipped${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "\n${RED}${BOLD}SOME TESTS FAILED.${RESET} Review the output above."
    echo ""
    echo "Diagnostic commands (from host):"
    echo "  docker logs agent-sandbox-sidecar-*   # sidecar proxy decisions"
    echo "  docker exec <sidecar> cat /var/log/mitmproxy.log"
    echo ""
fi

exit "$FAIL_COUNT"
