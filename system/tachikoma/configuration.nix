{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    # Vendored sysbox runtime (see ../sysbox-nix/). The module is a
    # function-of-flake; we apply it with a minimal stub that just
    # supplies the package built from our own nixpkgs (Option B —
    # direct import, no extra flake input). See ../sysbox-nix/README.md.
    (import ../sysbox-nix/modules/sysbox.nix {
      packages.${pkgs.stdenv.hostPlatform.system}.sysbox = pkgs.callPackage ../sysbox-nix/pkgs { };
    })
  ];

  virtualisation.docker.enable = true;
  # Pin Docker to 29.4.3 (from the nixpkgs-docker input). sysbox-runc
  # 0.6.7 doesn't support Docker 29.5+ (which injects a "time"
  # namespace by default and changed stdio/console fd handling) —
  # containers fail to start with sysbox-runc. 29.4.3 is the last
  # known-good release (nestybox/sysbox#1011), one minor behind 29.5.
  # Revisit once upstream sysbox supports 29.x.
  virtualisation.docker.package =
    inputs.nixpkgs-docker.legacyPackages.${pkgs.stdenv.hostPlatform.system}.docker_29;
  virtualisation.docker.daemon.settings = {
    hosts = [
      "unix:///var/run/docker.sock"
      "tcp://0.0.0.0:2375"
    ];
    # work around issue with check point VPN - apparently auto MTU
    # discovery breaks at some point down the line
    mtu = 1350;
  };
  users.users.nixos.extraGroups = [ "docker" ];

  networking.hostName = "tachikoma";

  # Register sysbox-runc as a Docker runtime:
  #   docker run --runtime=sysbox-runc ...
  virtualisation.sysbox.enable = true;

  # The sysbox module raises these inotify limits with mkDefault,
  # but nixpkgs also defaults them (to a lower value) at the same
  # priority — a tie Nix refuses to resolve. Force sysbox's value.
  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = lib.mkForce 1048576;
    "fs.inotify.max_user_instances" = lib.mkForce 1048576;
    "kernel.pid_max" = lib.mkForce 4194304;
  };

  # Build aarch64 closures for nyc-08 here rather than on the VM itself.
  # Emulated builds still produce native aarch64 store paths, so cache.nixos.org
  # substitutes almost everything and only uncached derivations run under qemu.
  # This also adds aarch64-linux to nix.settings.extra-platforms.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Any binfmt registration replaces WSL's own handler for .exe files, so the
  # WSLInterop registration has to be re-added explicitly alongside the qemu one.
  wsl.interop.register = true;
}
