# sysbox-nix

Nix flake for [Sysbox](https://github.com/nestybox/sysbox) — a rootful OCI container runtime that runs system containers (containers that can run systemd, Docker, K8s inside).

Pin: **v0.6.7**. Builds three components separately with `buildGoModule`: `sysbox-fs`, `sysbox-mgr`, `sysbox-runc`. Ships a NixOS module that wires them into systemd and registers `sysbox-runc` as a Docker runtime.

Not in nixpkgs. Linux only (`x86_64-linux`, `aarch64-linux`).

## Usage

### As a flake input

```nix
{
  inputs.sysbox.url = "github:polferov/sysbox-nix";

  outputs = { self, nixpkgs, sysbox, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sysbox.nixosModules.sysbox
        ({ ... }: {
          virtualisation.docker.enable = true;
          virtualisation.sysbox.enable = true;
        })
      ];
    };
  };
}
```

### Just the package

```
nix build github:polferov/sysbox-nix
./result/bin/sysbox-runc --version
```

Outputs: `result/bin/{sysbox-fs,sysbox-mgr,sysbox-runc}`.

## Requirements

- **Kernel ≥ 5.12** — idmapped mounts. Module asserts this. Shiftfs path (deprecated upstream) is not packaged.
- **subuid/subgid ranges** — sysbox-mgr allocates per-container user-namespace ranges from `/etc/subuid` and `/etc/subgid`. Configure on NixOS via:
  ```nix
  users.users.<name>.subUidRanges = [ { startUid = 100000; count = 65536; } ];
  users.users.<name>.subGidRanges = [ { startGid = 100000; count = 65536; } ];
  ```
  Sysbox itself runs as root, but containers it launches need pool space — defaults are usually fine, just ensure the pool is large enough for the container count you want.

## What the module does

- Builds `cfg.package` (default: flake's `sysbox`) into `environment.systemPackages`.
- Sets `boot.kernel.sysctl` for inotify, keyring, pid_max, unprivileged userns (upstream defaults).
- Loads `configfs` kernel module.
- Creates systemd units `sysbox-mgr`, `sysbox-fs`, `sysbox` (wrapper) — mirrors upstream `sysbox-pkgr/systemd/`.
- If `virtualisation.docker.enable = true`, registers `sysbox-runc` runtime in `docker daemon.json`. Disable via `virtualisation.sysbox.registerDockerRuntime = false`.

## Verification

```sh
nix flake check
nix build .#sysbox
./result/bin/sysbox-runc --version    # v0.6.7
./result/bin/sysbox-mgr --help
./result/bin/sysbox-fs --help
```

End-to-end (requires a NixOS host with module enabled):

```sh
docker run --runtime=sysbox-runc -it --rm alpine sh -c 'cat /proc/self/uid_map'
# Expect: non-identity mapping (e.g. "0 100000 65536"), proving userns isolation.
```

## Troubleshooting

### `boot.kernel.sysctl.*` defined multiple times

```
error: The option `boot.kernel.sysctl."fs.inotify.max_user_instances"' is defined multiple times while it's expected to be unique.
- In `<nixpkgs>/nixos/modules/config/sysctl.nix': 524288
- In `<sysbox>/modules/sysbox.nix': 1048576
```

Sysbox sets several sysctls with `lib.mkDefault`. When nixpkgs (or another module) sets the same key at `lib.mkDefault` with a different value, the module system can't pick a winner and errors out. Override in your own config with `lib.mkForce`.

Known conflicts with current nixpkgs (`config/sysctl.nix`):

| Key | nixpkgs `mkDefault` | sysbox `mkDefault` |
|---|---|---|
| `fs.inotify.max_user_instances` | `524288` | `1048576` |
| `fs.inotify.max_user_watches` | `524288` | `1048576` |

Drop-in fix — paste into any NixOS module in your config:

```nix
{ lib, ... }:
{
  boot.kernel.sysctl = {
    "fs.inotify.max_user_instances" = lib.mkForce 1048576;
    "fs.inotify.max_user_watches"   = lib.mkForce 1048576;
    # Uncomment if another module also sets these at mkDefault:
    # "fs.inotify.max_queued_events"      = lib.mkForce 1048576;
    # "kernel.unprivileged_userns_clone"  = lib.mkForce 1;
    # "kernel.keys.maxkeys"               = lib.mkForce 20000;
    # "kernel.keys.maxbytes"              = lib.mkForce 1400000;
    # "kernel.pid_max"                    = lib.mkForce 4194304;
  };
}
```

Values match what `modules/sysbox.nix` requests. Lower them if you have a reason — sysbox just needs headroom, not these exact numbers.

## Why a fork-and-flake instead of upstream

Upstream's `make sysbox` shells out to Docker to compile inside a container. That's incompatible with Nix's pure-build model. This flake calls `go build` per component directly. Build tags hardcode `seccomp apparmor idmapped_mnt` (kernel ≥ 5.12 assumed); static linking is dropped in favor of Nix's runtime closure.

## Layout

```
flake.nix
pkgs/
  common.nix        — shared src + version + ldflags
  default.nix       — symlinkJoin combining the three
  sysbox-fs.nix
  sysbox-mgr.nix
  sysbox-runc.nix
modules/
  sysbox.nix        — NixOS module
```

## Updating

1. Bump `version` in `pkgs/common.nix`.
2. Set `hash` in `common.nix` and all three `vendorHash` values to `lib.fakeHash`.
3. Run `nix build .#sysbox-runc` (then fs, then mgr) — copy the `got:` hash from each error and paste back.
4. Commit.
