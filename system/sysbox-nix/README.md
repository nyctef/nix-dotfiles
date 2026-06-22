# Vendored: sysbox-nix

A source-based Nix flake + NixOS module that builds the [Sysbox][sysbox]
container runtime (a `runc` replacement that runs system containers — its own
`dockerd`, systemd, etc. — inside *unprivileged* containers via user
namespaces + idmapped mounts).

We vendor it rather than consume it as a live flake input because upstream is
young (single maintainer, ~10 commits) and builds third-party code; pinning a
reviewed copy keeps it tamper-evident and removes surprise upstream changes.

## Provenance

- **Upstream repo:** https://github.com/polferov/sysbox-nix
- **Commit:** `09799d4c4e493a9431b084cd95074a7beb2d364a`
- **Committed:** 2026-05-31T11:06:08Z
- **Vendored:** 2026-06-22
- **License:** MIT (see `upstream/LICENSE`, © Kirill Polferov) — this covers the
  *packaging* code only. The Sysbox source it builds
  (`nestybox/sysbox` @ `v0.6.7`) is Apache-2.0 and is fetched at build time
  from the official repo via a pinned `fetchFromGitHub` hash, not vendored here.

The `.nix` files (`modules/sysbox.nix`, `pkgs/*.nix`) and `LICENSE` are copied
**byte-for-byte** from the commit above.

## Local changes

We integrate via direct import (Option B — no extra flake input), so the
upstream flake plumbing is unused. Relative to upstream:

- **Removed** (unused under direct import): `flake.nix`, `flake.lock`,
  `.gitignore`, and upstream's own `README.md`.
- **Flattened** `upstream/` → this directory (so paths are
  `system/sysbox-nix/{modules,pkgs}/…`).
- The `.nix` file *contents* are unmodified. The module is a
  function-of-flake; `flake.nix` (tachikoma) applies it with a stub
  `{ packages.<system>.sysbox = …; }` that supplies a package built from our
  own nixpkgs via `callPackage ./pkgs`.

Keep the `.nix` files byte-for-byte upstream so re-syncs stay a clean diff.

### Integration note (in `flake.nix`, not here)

The module raises three sysctls (`fs.inotify.max_user_watches`,
`fs.inotify.max_user_instances`, `kernel.pid_max`) with `mkDefault`, but
nixpkgs also defaults them at the same priority — an unresolvable tie. The
`tachikoma` config overrides them with `lib.mkForce` to take sysbox's values.
If a re-sync changes the module's sysctl set, revisit those overrides.

## Why it suits this host (tachikoma, NixOS + WSL2)

- Kernel 6.18 ≥ 5.19 → idmapped mounts replace shiftfs (which is absent here).
- systemd PID 1, real Docker Engine (runc default) — the module registers
  `sysbox-runc` as a Docker runtime.
- See the build derivations in `upstream/pkgs/` and the NixOS module in
  `upstream/modules/sysbox.nix`.

## Re-syncing with upstream

```sh
# bump the commit, re-fetch verbatim, then re-review the diff under upstream/pkgs
gh api repos/polferov/sysbox-nix/contents/<path>?ref=<sha> --jq .content | base64 -d
```

[sysbox]: https://github.com/nestybox/sysbox
