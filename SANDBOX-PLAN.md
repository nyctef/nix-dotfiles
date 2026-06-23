# Sandbox rework — status & plan (scratch)

> Working notes, **not committed**. Goal: build a **new** sandbox script (kept
> separate from the existing `utils/run-claude-docker.sh`, which stays working
> untouched for now) so an *untrusted AI agent* can run with Docker access and
> network egress without being able to reach the host or exfiltrate freely.
> Informed by a reverse-engineering study of Docker `sbx` (host-side TLS MITM
> proxy for credential injection + Cedar egress policy + microVM isolation).
>
> **Approach:** greenfield script developed alongside the current one — no edits
> to `run-claude-docker.sh` until the new path is proven and we choose to
> cut over (or retire the old one). This lets us iterate on the hardened design
> without breaking the working daily driver.

## Threat model (the framing that drives every decision)

- **The agent (Claude) is the adversary.** Not the test databases it spins up.
- Therefore the agent's container must be **unprivileged** and must **not** hold
  the host Docker socket. Anything that leaves the agent in a privileged
  container (incl. single-container rootful/rootless dind) is ~no better than
  today's `--docker` host-socket mount (one hop to host root).
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

---

## CURRENT STATUS (2026-06-22)

### Done
- **Environment validated** on `tachikoma` (NixOS 26.05, WSL2, kernel 6.18):
  systemd PID 1 ✓, real Docker Engine (runc default) ✓, idmapped mounts
  (`idmap.enabled: true`) ✓ → shiftfs not needed, FUSE ✓, unprivileged userns ✓,
  cgroup v2 ✓. `.wslconfig` not in `networkingMode=mirrored` (the one known WSL
  breaker) ✓.
- **Vendored** `polferov/sysbox-nix` @ `09799d4` (2026-05-31) into
  `system/sysbox-nix/`. MIT LICENSE kept; `.nix` files byte-for-byte. Unused
  flake plumbing removed (direct-import integration). Provenance + local-changes
  in `system/sysbox-nix/README.md`. Builds **sysbox v0.6.7** from pinned
  `nestybox/sysbox` source via 4 content hashes (tamper-evident).
- **Build validated** two ways → identical store path
  `…-sysbox-0.6.7` (`ivszr4vi…`); vendorHashes compatible with our nixpkgs.
- **Integrated into `tachikoma`** (commit `ca248f2`, Option B / direct import):
  - `import ./system/sysbox-nix/modules/sysbox.nix { packages… = callPackage ./pkgs; }`
  - `virtualisation.sysbox.enable = true;` → registers `sysbox-runc` docker runtime
  - `lib.mkForce` on `fs.inotify.max_user_watches`, `…max_user_instances`,
    `kernel.pid_max` to resolve priority ties with nixpkgs defaults
  - **config evaluates clean**; runtime registered; package = validated build.

- **Activated** — `nixos-rebuild switch` applied; `sysbox-mgr`/`sysbox-fs`/`sysbox`
  services up, `sysbox-runc` runtime registered. subuid/subgid sorted itself out
  (no declarative `users.users.sysbox` needed).
- **Diagnosed sysbox 0.6.7 ✗ Docker 29.5 version skew → pinned Docker to 25.x.**
  Smoke test on Docker 29.5.1 failed in two stages:
  1. `OCI runtime create failed: namespace {"time" ""} does not exist` — Docker
     29.5.0 injects a private `time` namespace into every container's OCI spec
     (moby/moby#52326), unsupported by sysbox-runc (nestybox/sysbox#1011).
     Worked around with `features."time-namespaces" = false`, which exposed:
  2. `getting pipe fds … readlink /proc/<pid>/fd/0: no such file or directory` —
     sysbox-mgr/fs register then immediately unregister the container; the
     init/console-fd path in `sysbox-runc` fails. Another facet of the same skew
     (Docker 29.5 changed stdio/console handling).
  Upstream evidence is decisive: #1011 shows plain `debian:bookworm-slim` works on
  Docker **29.4.3** and breaks on **29.5.0**, and the reporter is on sysbox **0.7.0**
  (latest) — so upstream's newest release doesn't support 29.5 either. Chasing
  per-symptom workarounds is whack-a-mole. **Fix: pin Docker below 29.5.**
  Current nixpkgs unstable exposes only `docker_25` (25.0.16) and `docker_29`
  (29.5.3) — no 29.4.x — so set `virtualisation.docker.package = pkgs.docker_25`
  (predates the time-namespace change; within sysbox's supported range). Reverted
  the `time-namespaces` workaround (moot below 29.5). **Revisit** when upstream
  sysbox supports 29.x, or pin a dedicated nixpkgs input for 29.4.x if 25 is too old.

### Pending
- **Re-run smoke test** after `nixos-rebuild switch` with Docker pinned to 25.x
  (dockerd restarts). Confirm `docker run --runtime=sysbox-runc docker:dind`
  starts inner dockerd unprivileged.

### Commits
- `1d21069` vendor polferov/sysbox-nix for review
- `ca248f2` integrate vendored sysbox into tachikoma (Option B)

---

## NEXT: re-run smoke test (sysbox activated; `time-namespaces` fix applied)

Activated once already (see Done). After the `time-namespaces = false` fix,
re-apply and re-smoke-test:
```sh
sudo nixos-rebuild switch --flake ~/.dotfiles#tachikoma
```
Effects / watch-outs:
- Starts `sysbox-mgr`, `sysbox-fs`, `sysbox` services.
- **Restarts `docker.service`** (sysbox unit orders `Before=docker.service`) →
  running containers stop. Do it when idle.
- **Most likely friction — subuid/subgid.** sysbox-mgr allocates a range for a
  `sysbox` user at startup; `/etc/subuid`/`/etc/subgid` are declaratively managed
  on NixOS. If it errors, add a declarative `users.users.sysbox` (+ subuid/subgid
  entry) — would become a tracked integration addition (like the sysctl forces).

### Smoke test (after activation)
```sh
systemctl status sysbox-mgr sysbox-fs --no-pager
docker run --rm --runtime=sysbox-runc -it docker:dind   # inner dockerd, unprivileged
# inside: `docker run hello-world`; on host: confirm container is NOT privileged
```

---

## FUTURE: the sandbox itself (a NEW script, alongside the existing one)

Build a fresh script (working name e.g. `utils/run-claude-sandbox.sh`) rather
than editing `run-claude-docker.sh`. The current script keeps running unchanged
as the daily driver; the new one is where the hardened design lands. Reuse what
already works by copying/extracting (worktree setup, Nix symlink resolution,
mount helpers, the Ctrl-Z rcfile trick) — don't refactor the old script to share
code yet. Decide on cutover (replace vs keep both) only once the new path is
proven end-to-end.

Build order — each phase is independently shippable.

### Phase A — run the agent under sysbox (new script skeleton)
- New script launches the agent container with `--runtime=sysbox-runc`; installs
  dockerd *inside* the image; has **no host-socket mount at all** (the old
  script's `--docker` flag is simply not carried over).
- Inner daemon data-root on a **per-instance** volume (`/var/lib/docker`) so
  parallel agents never share a data-root. Optional host **registry
  pull-through mirror** (`registry:2` + `REGISTRY_PROXY_REMOTEURL`) for warm
  caches without sharing storage.
- Outcome: `dotnet test → docker run` works with native ergonomics; agent
  unprivileged; test-DB containers nested inside, not host siblings.

### Phase B — network: flip policy L3/L4 → L7 (biggest correctness win)
- Replace dnsmasq+ipset+iptables IP-allowlisting with:
  - **iptables = dumb mandatory floor**: default-deny egress, allow only DNS to
    resolver + the proxy port; final `REJECT` kills all non-HTTP (raw TCP, QUIC,
    C2). Block **UDP 443** (force QUIC→TCP) and **853** (DoT).
  - **in-container proxy = policy brain**: owns hostname allowlist (SNI + Host),
    reuse `/etc/firewall-domains.txt`. Reject **domain fronting** (Host≠SNI).
- Two enforcement modes: explicit (`HTTPS_PROXY` + CA trust) vs **transparent**
  (iptables `REDIRECT` + uid-owner split: agent uid → proxy, proxy uid → free)
  so it can't be bypassed even if the app ignores `HTTP_PROXY`.
- **Caveat (carry forward):** transparent mode relies on plaintext SNI;
  SNI-less / ECH traffic is opaque. Mitigate via DNS (strip ECH HTTPS records)
  or full MITM (Host header). These AI/API endpoints send normal SNI today.
- **Note:** containers the agent spawns get their own netns → must also be
  forced through the egress controls, or they bypass the firewall (this is the
  exact gap the current `--docker` warning calls out).

### Phase C — credential injection (keep secrets off the agent) — sbx model
- Generate a per-run CA; install trust via the sbx env-var set
  (`SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`)
  + Java keytool import.
- Proxy addon injects creds by **detected service** (domain→service table) and/or
  **placeholder substitution** (agent holds a fake token, proxy swaps the real
  one outbound). Real secrets read from host (env/keychain), never enter the VM.
- Lets us stop mounting real creds (`~/.config/gh`, NuGet token, Anthropic) into
  the container — resolves existing TODOs in run-claude-docker.sh.
- git over HTTPS with token injection; SSH (port 22) stays default-denied unless
  explicitly allowed.

### Cross-cutting / carry over from the old script
- Worktree mode, host-absolute-path mounts, Nix symlink resolution, Ctrl-Z
  rcfile trick, build-arg version pinning — copy these into the new script as
  needed (extract verbatim; don't share code with the old one yet).
- Make firewall/proxy **fail-closed and self-verifying**: assert a blocked host
  fails AND an allowed host succeeds (current check only tests the blocked case).

---

## Open questions / decisions parked
- ~~subuid/subgid handling on NixOS~~ — resolved at activation (worked out of the box).
- Proxy implementation: mitmproxy (batteries-included, Python addon) vs small Go
  proxy (better at hijacked/streamed conns; lighter). For pure outbound HTTPS,
  mitmproxy is fine; revisit if we ever proxy the docker socket too.
- Whether to also keep a body-authorizing docker-socket proxy as defense-in-depth
  even under sysbox (probably not load-bearing once the agent is unprivileged).
