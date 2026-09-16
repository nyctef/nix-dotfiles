# agent-sandbox

A hardened sandbox for running an AI coding agent (Claude Code, pi-dev) with
Docker access and network egress, without letting it reach the host or exfiltrate
freely.

The agent container runs under `--runtime=sysbox-runc`, so it is **unprivileged
with real UID remapping** yet can run its **own dockerd nested inside**. That
gives native `dotnet test → docker run -p` ergonomics (single netns, `localhost`,
bind mounts) without ever handing the agent the host Docker socket.

All egress goes through a **sidecar proxy container** that enforces a hostname
allowlist, makes GitHub read-only, and injects real credentials in-flight so the
agent never holds them.

## Usage

Run from any project directory — `$PWD` is mounted as the working dir.

```
run-claude-sandbox [--worktree <name>] [claude args...]
run-pi-sandbox     [--worktree <name>] [pi args...]
```

`--worktree <name>` branches a git worktree from HEAD and mounts that as the
working dir instead, with the main repo mounted read-only alongside. Reusing an
existing worktree with uncommitted changes is refused rather than reset.

Both are thin wrappers over the generic core, which can drive any agent:

```
run-agent-sandbox --agent-cmd <cmd> [options] [-- agent args...]

  --agent-cmd <cmd>        Command to run as the agent (required).
  --mount <mode>:<host>:<container>
                           Extra bind mount; repeatable. mode = ro|rw. Host
                           paths are resolved (readlink -f); symlinks beneath
                           them are not followed, since /nix/store is mounted
                           ro. Missing host paths are skipped.
  --env <NAME=VALUE>       Extra env var; repeatable.
  --worktree <name>        As above.
  --anthropic-cred <kind>  Which Anthropic credential the sidecar provisions:
                           "oauth" (Claude Code), "apikey" (pi and other SDK
                           agents), or "none" (default). Exactly one per run —
                           provisioning both would let the x-api-key service
                           override the OAuth Bearer.
```

Each run gets its own container, sidecar, network, CA, and Docker data-root
(all suffixed with the launcher's PID), so parallel sandboxes never collide.
Everything is removed on exit.

## Architecture

```
┌─── Host Docker ──────────────────────────────────────────────┐
│                                                              │
│  ┌── sandbox-internal-$$ (Docker --internal network) ──────┐ │
│  │                                                          │ │
│  │  ┌─ Agent Container (sysbox-runc) ─────────────────┐    │ │
│  │  │  claude user → agent process                     │    │ │
│  │  │  inner dockerd → nested containers               │    │ │
│  │  │  HTTP_PROXY/HTTPS_PROXY → sidecar                │    │ │
│  │  │  CA from sidecar (shared volume, read-only)      │    │ │
│  │  └──────────────────────────┬───────────────────────┘    │ │
│  │                             │ HTTP(S) CONNECT            │ │
│  │  ┌─ Sidecar Container ─────┴──────────────────────┐     │ │
│  │  │  mitmproxy (forward proxy mode)                │     │ │
│  │  │  egress-policy.py  (hostname allowlist)         │     │ │
│  │  │  github-policy.py  (GitHub read-only)           │     │ │
│  │  │  cred-inject.py    (placeholder → real creds)   │     │ │
│  │  └──────────────────────────┬─────────────────────┘     │ │
│  └─────────────────────────────│─────────────────────────────┘ │
│                                │ allowed traffic only          │
│  ┌── default bridge ──────────┴────────────────────────────┐ │
│  │                     Internet                            │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

The agent container sits on a Docker `--internal` network, which installs
host-level iptables rules (`DOCKER-INTERNAL`) that DROP any packet with a
non-subnet destination. The sidecar is on both that network and the default
bridge, so it is the only route out.

This is what makes egress **mandatory rather than cooperative**: `HTTP_PROXY` is
a hint an app can ignore, but ignoring it here just means the connection is
dropped. Enforcement lives in host iptables and cannot be modified from inside
any container, even with root and `NET_ADMIN`. The proxy process, policy addons,
and allowlist are all in the sidecar's filesystem, where the agent can't read,
modify, or kill them.

## Threat model

**The agent is the adversary** — not the test databases it spins up. Everything
above follows from that:

- The agent's container must be unprivileged and must not hold the host Docker
  socket. Anything leaving the agent in a privileged container (including
  single-container rootful/rootless dind) is roughly equivalent to mounting the
  host socket: one hop to host root.
- Egress policy is expressed at **L7 (hostname/SNI/Host)**, not L3/L4 (resolved
  IPs), to avoid CDN/shared-IP leaks and domain fronting. The proxy rejects
  requests where the Host header disagrees with the SNI.
- Real credentials never enter the agent container.
- **`/nix/store` is mounted read-only** so Home Manager dotfiles (`CLAUDE.md`,
  skills, jj/git config) resolve — they are symlinks into the store, and a live
  mount is what keeps them working when a `home-manager switch` mid-run
  repoints them at a fresh store path. Nix-wrapped agents such as pi need it
  too, for their closure. The agent can therefore read and execute anything in
  the host store, not just the toolchain baked into the image. This is
  deliberate: the store is world-readable on the host by design and holds no
  live credentials (agenix secrets exist there only as ciphertext and decrypt to
  `$XDG_RUNTIME_DIR/agenix` on tmpfs, which is never mounted into the agent).
  Extra binaries buy no egress — the sidecar enforces at the network layer.

| Attack | Outcome |
|---|---|
| Agent ignores `HTTP_PROXY` | Blocked (network topology) |
| Agent gains root, flushes its own iptables | No effect (enforcement is host-level) |
| Agent kills the proxy process | Impossible (process is in the sidecar) |
| Agent modifies the allowlist or policy addons | Impossible (files aren't in its filesystem) |
| Domain fronting (Host ≠ SNI) | Rejected by proxy |
| QUIC / DNS-over-TLS / raw TCP exfil | Blocked (no route out of `--internal`) |
| Nested container egress | Routed through the sidecar like everything else |
| `apt-get` postinst scripts | Routed through the sidecar |
| Agent gets container root (via `sudo apt-get -o ...` or the docker group) | Expected; root is still an unprivileged host subuid, egress and credentials are unaffected |

## Credentials

Real credentials are held **only by the sidecar**, passed to it via
`SANDBOX_CRED_*` env vars. The agent container gets `SANDBOX-PLACEHOLDER-*`
tokens in its config files and env, and the proxy swaps them for real values on
outbound requests. `credential-map.yaml` maps domain → service → env var and
supports three injection modes:

- `github` — auto-detects API vs git-over-HTTPS
- `basic_auth` — NuGet/VSTS feeds
- `header` — Anthropic `x-api-key`, Claude OAuth Bearer

The agent reaches GitHub through a git credential helper
(`/opt/sandbox/git-credential-sandbox.sh`) and `GH_TOKEN` that return
placeholders. Host gitconfig credential-helper sections are stripped, and
`.credentials.json` is masked with an empty file.

Claude Code authenticates with `CLAUDE_CODE_OAUTH_TOKEN` rather than
`ANTHROPIC_API_KEY`, to avoid Claude Code's interactive "Detected a custom API
key" prompt.

## GitHub is read-only

GitHub is a large surface for both prompt injection (read) and exfiltration
(write). Dropping GitHub access entirely would cost most of the agent's value,
so instead the blast radius of a hijacked agent is bounded:

- **Reads are open.** GET/HEAD to any GitHub host, plus GraphQL `query`
  operations (the request body is parsed to classify them).
- **Writes are blocked.** Every POST/PUT/PATCH/DELETE, `git push`
  (receive-pack), and every GraphQL `mutation` is 403'd. The exception is
  `POST .../git-upload-pack`, which is how smart-HTTP serves a clone/fetch.

`github-policy.py` runs between `egress-policy.py` and `cred-inject.py`, so a
blocked write is rejected *before* a real credential is ever minted onto it.

**Residual risk:** reads remain fully open, so read-side exfil is still possible.
This is a blast-radius control, not a wall.

## Configuration

| file | role |
|---|---|
| `firewall-domains.txt` | hostname allowlist — single source of truth for egress policy |
| `credential-map.yaml` | domain → service → env-var mapping for credential injection |

Add a hostname to `firewall-domains.txt` to allow it; subdomains of listed
domains match. Both files live in the sidecar image, so a rebuild is needed for
changes to take effect.

## Files

| file | role |
|---|---|
| `default.nix` | packages the folder into the Nix store; PATH-wraps the launchers |
| `run-claude-sandbox.sh` | Claude wrapper — claude cmd/binary/config mounts/env |
| `run-pi-sandbox.sh` | pi wrapper — pi binary (Nix closure), config/state mounts/env |
| `run-agent-sandbox.sh` | generic core — worktree, build, network, sidecar, `docker run` |
| `Dockerfile` | agent image — full `dockerd` inside, no host socket, no proxy |
| `Dockerfile.sidecar` | sidecar image — mitmproxy forward proxy, L7 egress policy |
| `entrypoint.sh` | in-agent: install CA, configure proxy env, start inner dockerd, run agent |
| `sidecar-entrypoint.sh` | in-sidecar: start mitmproxy in forward mode, signal ready |
| `egress-policy.py` | mitmproxy addon — hostname allowlist (SNI + Host), anti-fronting |
| `github-policy.py` | mitmproxy addon — GitHub read-only enforcement |
| `graphql_lex.py` | GraphQL operation classifier (query vs mutation) |
| `cred-inject.py` | mitmproxy addon — credential injection (placeholder → real) |
| `test-sandbox-egress.sh` | test wrapper — drives the core with the harness as the "agent" |
| `egress-test-harness.sh` | in-container test suite — exercises every layer |

## Testing

```
test-sandbox-egress [--no-docker]
```

Drives the real launcher with `egress-test-harness.sh` bind-mounted in as the
agent command, so the suite runs as the `claude` user inside a genuine sandbox —
exactly the threat model being tested. `--no-docker` skips the inner-dockerd and
nested-container tests and is considerably faster. Exit status is the failure
count.

Coverage includes: allowed/blocked hosts, subdomain matching, direct-connection
and raw-TCP bypass attempts, proxy CA trust (curl/python/java), Java and Maven
proxy configuration, sidecar unreachability, root-escalation and iptables-flush
resilience, inner dockerd, nested container egress, credential placeholders, and
the GitHub read-only policy.

One test reports as skipped by design: **domain fronting** needs DNS resolution
from the agent container, which the `--internal` network doesn't provide. The
anti-fronting check itself is live in `egress-policy.py`; only the in-container
driver for it can't run.

## Tool-specific notes

Most tools pick up `HTTP_PROXY`/`HTTPS_PROXY` and the CA from the standard env
vars (`SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`,
`NODE_EXTRA_CA_CERTS`). These ones need special handling, all done by
`entrypoint.sh`:

- **apt** — `sudo` resets the environment (`env_reset`), so `sudo apt-get`
  never sees `HTTP_PROXY`. A persistent `/etc/apt/apt.conf.d/99sandbox-proxy`
  is written instead.
- **Java** — the JVM ignores `HTTP_PROXY`/`HTTPS_PROXY` entirely; it only reads
  the `http.proxyHost`/`https.proxyHost` system properties. Set for every JVM
  via `JAVA_TOOL_OPTIONS`. Note this makes every JVM print `Picked up
  JAVA_TOOL_OPTIONS: ...` on startup.
- **Maven** — needs a *second* fix: its resolver uses Apache HttpClient, which
  doesn't read the JVM proxy properties either. The global
  `/etc/maven/settings.xml` is overwritten with a `<proxies>` block. Note that
  `nonProxyHosts` can't take CIDR the way `NO_PROXY` does — it's `|`-separated
  globs, so the private ranges are expanded to prefix wildcards.
- **inner dockerd** — gets proxy config via
  `/etc/systemd/system/docker.service.d/proxy.conf` so registry pulls route
  through the sidecar.

## Limitations

- **Nested containers have no CA.** Containers started by the inner dockerd
  don't get the MITM CA, so outbound HTTPS from inside them fails with cert
  errors. Fine for the common case (test databases don't make outbound HTTPS);
  agent work happens in the outer container.
- **Private Docker registries don't work.** Registry auth needs the `/v2/token`
  exchange flow intercepted, which `cred-inject.py` doesn't do yet.
- **GraphQL classification is coarse by design.** Reads are allowed and
  mutations blocked, but any `gh` command routing a *write* through GraphQL
  fails in-sandbox. Use the REST equivalent (`gh api -X GET …`) or run those
  workflows outside the sandbox.
- **No OpenAI/Google/OpenRouter credential injection.** Those keys get
  placeholder env vars so an SDK will start, but the sidecar doesn't inject real
  values. Extend `credential-map.yaml` and `cred-inject.py` when needed.
- **Gradle and Flyway aren't specially configured.** The Gradle daemon should
  inherit `JAVA_TOOL_OPTIONS`, and Flyway's bundled JRE has its own keystore
  that doesn't receive the CA. Neither is confirmed working.
- **ECH would hide SNI from the proxy.** Current endpoints send normal SNI; if
  that changes, mitigate via DNS (stripping ECH HTTPS records).

## Host requirements

Runs on `tachikoma` (NixOS 26.05, WSL2, kernel 6.18). Requirements: systemd as
PID 1, real Docker Engine, idmapped mounts or shiftfs, FUSE, unprivileged
userns, cgroup v2, and — on WSL — `.wslconfig` **not** set to
`networkingMode=mirrored`, which breaks sysbox.

Sysbox is enabled declaratively via the vendored `system/sysbox-nix/`
(`virtualisation.sysbox.enable = true`), built from pinned upstream source via
content hashes.

**Docker is pinned to 29.4.3** via a dedicated `nixpkgs-docker` flake input that
deliberately does *not* follow `nixpkgs`. Sysbox 0.6.7/0.7.0 break on Docker
29.5 (private `time` namespace injection — moby#52326, nestybox/sysbox#1011,
plus changed stdio/console handling). Revisit when upstream sysbox supports
29.5+, then drop the input.

The launcher fails fast with a clear message if the `sysbox-runc` runtime isn't
registered.
