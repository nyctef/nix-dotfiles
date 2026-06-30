# agent-sandbox

The **new** hardened sandbox for running an *untrusted AI coding agent* (Claude
Code today; pi-dev and others later) with Docker access and network egress,
without letting it reach the host or exfiltrate freely. Developed alongside the
working `utils/run-claude-docker.sh` (which stays untouched as the daily driver)
— we cut over only once this path is proven end-to-end. Informed by a
reverse-engineering study of Docker `sbx` (host-side TLS MITM proxy for
credential injection + Cedar egress policy + microVM isolation).

The launcher is split into an **agent-agnostic core** and a thin
**Claude-specific wrapper**: the core takes the agent command, extra bind
mounts, and env vars as arguments; the wrapper supplies Claude's. Adding another
agent (pi-dev) is then a sibling wrapper, no core changes. The `claude`
user/home *inside the image* is still fixed (image-level) — generalising that is
deferred.

Unlike the old single-file script, the pieces are split into separate files:

| file                    | role                                                        |
|-------------------------|-------------------------------------------------------------|
| `default.nix`           | copies the folder into the store; PATH-wraps both launchers |
| `run-claude-sandbox.sh` | Claude wrapper — claude cmd/binary/config mounts/env, then calls the core |
| `run-agent-sandbox.sh`  | **generic core** — worktree, build, mounts, `docker run`    |
| `Dockerfile`            | agent image — full `dockerd` inside, **no host socket**     |
| `firewall-domains.txt`  | hostname allowlist — single source of truth for L7 egress policy        |
| `egress-policy.py`      | mitmproxy addon — enforces hostname allowlist (SNI + Host), anti-fronting |
| `init-egress-firewall.sh` | in-container: starts proxy, configures iptables, self-verifies        |
| `entrypoint.sh`         | in-container: start inner dockerd, init firewall, run agent as `claude` |
| `test-sandbox-egress.sh` | test wrapper — drives the core with a test harness as the "agent"     |
| `egress-test-harness.sh` | in-container test suite — exercises every layer of the network stack   |

## Core idea

The agent container runs under `--runtime=sysbox-runc`, so it is **unprivileged
with real UID remapping** yet can run its **own dockerd nested inside**. That
gives native `dotnet test -> docker run -p` ergonomics (single netns,
`localhost`, bind mounts) without ever handing the agent the host Docker socket
(the old `--docker` flag's one-hop-to-host-root, now gone).

## Threat model (the framing that drives every decision)

- **The agent (Claude) is the adversary.** Not the test databases it spins up.
- Therefore the agent's container must be **unprivileged** and must **not** hold
  the host Docker socket. Anything that leaves the agent in a privileged
  container (incl. single-container rootful/rootless dind) is ~no better than
  the old `--docker` host-socket mount (one hop to host root).
- Egress must be **mandatory** (kernel-enforced), not cooperative (`HTTP_PROXY`
  an app can ignore). Policy should be expressed at **L7 (hostname/SNI/Host)**,
  not L3/L4 (resolved IPs), to avoid CDN/shared-IP leaks and domain fronting.

## Why sysbox (the enabling prerequisite)

Sysbox (`sysbox-runc`) runs a container's *own* dockerd **unprivileged** via
user namespaces + idmapped mounts. That uniquely gives both:
- **ergonomics**: single network namespace → `localhost:5432` and bind mounts
  work like a dev box (matches the `dotnet test → docker run -p` workflow);
- **isolation**: the agent container is not privileged → no trivial host escape.

The alternative (unprivileged agent + privileged dind sidecar + body-filtering
socket proxy) also keeps the agent unprivileged but is more moving parts and
reintroduces port/path remapping. Sysbox collapses those layers.

Sysbox is enabled declaratively in this repo via the vendored
`system/sysbox-nix/` (`virtualisation.sysbox.enable = true`). See
**Sysbox enablement** below for the full history.

## Build order — each phase is independently shippable

Reuse what already works by copying/extracting from `run-claude-docker.sh`
(worktree setup, Nix symlink resolution, mount helpers, the Ctrl-Z rcfile
trick) — we don't refactor the old script to share code yet.

### Phase A — run the agent under sysbox  ✅ scaffolded (untested)
- Launch the agent container with `--runtime=sysbox-runc`; install dockerd
  *inside* the image; **no host-socket mount at all** (the old `--docker` flag
  is simply not carried over).
- Inner daemon data-root on a **per-instance** volume (`/var/lib/docker`) so
  parallel agents never share a data-root. Optional host **registry
  pull-through mirror** (`registry:2` + `REGISTRY_PROXY_REMOTEURL`) for warm
  caches without sharing storage. *(mirror not yet implemented)*
- Outcome: `dotnet test → docker run` works with native ergonomics; agent
  unprivileged; test-DB containers nested inside, not host siblings.

### Phase B — network: flip policy L3/L4 → L7 (biggest correctness win)  ✅ proven
- Replaced dnsmasq+ipset+iptables IP-allowlisting with:
  - **iptables = dumb mandatory floor**: default-deny egress, allow only DNS to
    resolver + the proxy port; final `REJECT` kills all non-HTTP (raw TCP, QUIC,
    C2). Blocks **UDP 443** (force QUIC→TCP) and **853** (DoT).
  - **in-container proxy = policy brain** (mitmproxy transparent mode): owns
    hostname allowlist (`/etc/firewall-domains.txt`). Checks SNI + Host header.
    Rejects **domain fronting** (Host≠SNI).
- Enforcement is **transparent** (iptables `REDIRECT` + uid-owner split: all
  uids → proxy, proxy uid only → free) so it can't be bypassed even if the app
  ignores `HTTP_PROXY`.
- **No uid 0 exemption** — root traffic also goes through the proxy. The MITM
  CA is installed before dockerd starts (Go reads certs per-connection), so
  dockerd/containerd trust it for registry pulls. This closes the
  docker-group-to-root and sudo-postinst escalation paths.
- **Nested container egress blocked** via SANDBOX_FORWARD chain inserted at
  the top of FORWARD (before dockerd's DOCKER chains). Inner containers can
  talk to each other on private networks but cannot reach the internet.
- **Sudoers tightened** — only `apt-get` (not `dpkg` or `apt`). Even apt-get
  postinst scripts run as root, but root traffic goes through the proxy.
- Per-run CA generated by mitmproxy, installed into system trust store + Java
  keystore + standard env vars (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, etc.).
- Self-verifying: asserts blocked host fails AND allowed host succeeds, both
  as the agent user AND as root (uid 0 bypass check).
- Escapable via `SANDBOX_DISABLE_FIREWALL=1` for debugging.
- **Residual risk:** root inside the container can still `iptables -F` to flush
  all rules (the proxy keeps running but nothing redirects traffic to it).
  Phase B.1 (sidecar proxy) moves enforcement outside the container.
- **Caveat:** transparent mode relies on plaintext SNI; SNI-less / ECH traffic
  is opaque. Mitigate via DNS (strip ECH HTTPS records) or full MITM (Host
  header). These AI/API endpoints send normal SNI today.
- **Caveat:** nested containers don't have the MITM CA, so HTTPS from inside
  them fails with cert errors. This is acceptable (DB containers don't make
  outbound HTTPS; agent work happens in the outer container).

### Phase B.1 — sidecar proxy (move enforcement outside the container)
- Run mitmproxy in a **separate sidecar container** on a Docker `--internal`
  network. The agent container's only route to the internet goes through
  the sidecar. Even if the agent gains root and flushes iptables inside its
  own container, the sidecar's enforcement is unreachable.
- Architecture: sidecar on both `sandbox-net` (internal, no internet) and
  the default bridge (internet). Agent container on `sandbox-net` only.
  Sidecar acts as NAT gateway with mitmproxy as the policy point.
- CA sharing via a Docker volume (sidecar generates, agent container mounts).
- Sysbox should work with custom Docker networks (networking is orthogonal
  to the runtime).
- Closes the last in-container root risk: iptables tampering.

### Phase C — credential injection (keep secrets off the agent) — sbx model
- Generate a per-run CA; install trust via the sbx env-var set
  (`SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`)
  + Java keytool import.
- Proxy addon injects creds by **detected service** (domain→service table) and/or
  **placeholder substitution** (agent holds a fake token, proxy swaps the real
  one outbound). Real secrets read from host (env/keychain), never enter the VM.
- Lets us stop mounting real creds (`~/.config/gh`, NuGet token, Anthropic) into
  the container — resolves the existing TODOs in the launcher's mount block.
- git over HTTPS with token injection; SSH (port 22) stays default-denied unless
  explicitly allowed.

### Cross-cutting / carry over from the old script
- Worktree mode, host-absolute-path mounts, Nix symlink resolution, Ctrl-Z
  rcfile trick, build-arg version pinning — copied into the launcher (extracted
  verbatim; not shared with the old script yet).
- Make firewall/proxy **fail-closed and self-verifying**: assert a blocked host
  fails AND an allowed host succeeds (the old check only tested the blocked
  case).

## Open questions / decisions parked
- ~~subuid/subgid handling on NixOS~~ — resolved at activation (worked out of
  the box).
- Proxy implementation: mitmproxy (batteries-included, Python addon) vs small Go
  proxy (better at hijacked/streamed conns; lighter). For pure outbound HTTPS,
  mitmproxy is fine; revisit if we ever proxy the docker socket too.
- Whether to also keep a body-authorizing docker-socket proxy as
  defense-in-depth even under sysbox (probably not load-bearing once the agent
  is unprivileged).

---

## Current status: Phase A proven, Phase B proven

- ✅ Inner dockerd starts under sysbox-runc (validated on `tachikoma`)
- ✅ `docker run hello-world` works nested inside the agent container
- ✅ `default.nix` wired into `users/claude-code.nix` — `run-claude-sandbox`
  and `run-agent-sandbox` are on `PATH` after `home-manager switch`
- ✅ Phase B proven end to end: L7 proxy + iptables floor + no uid 0 bypass +
  nested container egress blocked + domain fronting rejected + sudoers tightened
- ✅ Test harness: `test-sandbox-egress` — 45 pass, 0 fail

Next step: **Phase B.1** — sidecar proxy (move enforcement outside the
container to close the iptables-flush escape). Then **Phase C** — credential
injection (keep secrets off the agent).

---

## Sysbox enablement (history & provenance)

Validated on `tachikoma` (NixOS 26.05, WSL2, kernel 6.18). This was the
enabling prerequisite for the whole sandbox design and is now **proven end to
end**: `docker run --runtime=sysbox-runc docker:dind` starts an inner dockerd,
`docker run hello-world` works nested inside, and the outer container is
unprivileged with real UID remapping (host `/proc/<pid>/uid_map` shows
container uid 0 → a high host subuid).

### Environment prerequisites (validated)
systemd PID 1 ✓, real Docker Engine ✓, idmapped mounts (`idmap.enabled: true`,
so shiftfs not needed) ✓, FUSE ✓, unprivileged userns ✓, cgroup v2 ✓,
`.wslconfig` not in `networkingMode=mirrored` (the one known WSL breaker) ✓.

### Vendoring
`polferov/sysbox-nix` @ `09799d4` (2026-05-31) vendored into
`system/sysbox-nix/` (MIT LICENSE kept, `.nix` files byte-for-byte, flake
plumbing removed for direct-import integration). Builds sysbox from pinned
`nestybox/sysbox` source via content hashes (tamper-evident). Integrated into
`tachikoma` via Option B (direct import) with `lib.mkForce` on the
inotify/pid_max sysctls to resolve priority ties with nixpkgs defaults.

### Hard-won fixes (the path to "proven end to end")
1. **Docker version skew → pinned Docker 29.4.3.** sysbox 0.6.7/0.7.0 break on
   Docker 29.5 (private `time` namespace injection — moby#52326,
   nestybox/sysbox#1011; plus changed stdio/console handling). 29.4.3 is the
   last known-good. Sourced from a dedicated pinned input `nixpkgs-docker`
   @ `8e4a6e1b8b11` (does *not* follow nixpkgs). **Revisit** when upstream
   sysbox supports 29.5+ → drop the input.
2. **Bumped vendored sysbox 0.6.7 → 0.7.0** — 0.7.0's openat2 trapping got past
   a silent nsenter init abort on kernel 6.18.
3. **sysbox-fs FUSE3** — 0.7.0 calls `fusermount3`; fixed `pkgs.fuse` →
   `pkgs.fuse3` on the service PATH.
4. **nsexec oom_score_adj patch** — nsexec unconditionally writes
   `oom_score_adj` (a kill-priority hint), which fails EACCES under sysbox's
   userns on this kernel and aborts container start. Patched to warn-and-
   continue. **Gotcha (cost hours):** the fix must target the **vendored** runc
   copy (`vendor/.../runc/libcontainer/nsenter/nsexec.c`) that cgo actually
   compiles — *not* sysbox-runc's own `libcontainer/nsenter` tree (dead code).
   Applied via `postConfigure` `substituteInPlace --replace-fail` (self-
   verifying).

### Commits (sysbox enablement)
- `1d21069` vendor polferov/sysbox-nix for review
- `ca248f2` integrate vendored sysbox into tachikoma (Option B)
- pin Docker 29.4.3 via dedicated `nixpkgs-docker` input
- bump vendored sysbox 0.6.7 → 0.7.0
- `sysbox-fs`: fuse3 (fusermount3) on service PATH
- `sysbox-runc`: oom-nonfatal patch on the vendored runc nsexec
