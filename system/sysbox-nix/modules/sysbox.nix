flake:
{ config, lib, pkgs, ... }:

let
  cfg = config.virtualisation.sysbox;
  defaultPkg = flake.packages.${pkgs.stdenv.hostPlatform.system}.sysbox or null;
in
{
  options.virtualisation.sysbox = {
    enable = lib.mkEnableOption "Sysbox container runtime";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPkg;
      defaultText = lib.literalExpression "sysbox.packages.\${system}.sysbox";
      description = "The sysbox package to use.";
    };

    registerDockerRuntime = lib.mkOption {
      type = lib.types.bool;
      default = config.virtualisation.docker.enable;
      defaultText = lib.literalExpression "config.virtualisation.docker.enable";
      description = ''
        Register sysbox-runc as a Docker runtime named `sysbox-runc` so that
        containers can opt in via `docker run --runtime=sysbox-runc ...`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "virtualisation.sysbox.package is null — set it explicitly or use a system with a flake-built sysbox.";
      }
      {
        assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version "5.12";
        message = "Sysbox requires kernel >= 5.12 (idmapped mounts). Bump boot.kernelPackages or pin a newer kernel.";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    # Sysbox needs user namespaces for unprivileged callers + inotify/keyring headroom.
    boot.kernel.sysctl = {
      "kernel.unprivileged_userns_clone" = lib.mkDefault 1;
      "fs.inotify.max_queued_events" = lib.mkDefault 1048576;
      "fs.inotify.max_user_watches" = lib.mkDefault 1048576;
      "fs.inotify.max_user_instances" = lib.mkDefault 1048576;
      "kernel.keys.maxkeys" = lib.mkDefault 20000;
      "kernel.keys.maxbytes" = lib.mkDefault 1400000;
      "kernel.pid_max" = lib.mkDefault 4194304;
    };

    boot.kernelModules = [ "configfs" ];

    systemd.tmpfiles.rules = [
      "d /var/lib/sysbox 0700 root root - -"
      "d /var/lib/sysbox-fs 0700 root root - -"
      "d /run/sysbox 0700 root root - -"
    ];

    systemd.services.sysbox-mgr = {
      description = "sysbox-mgr (part of the Sysbox container runtime)";
      partOf = [ "sysbox.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      # sysbox-mgr preflight shells out to rsync, modprobe, fsck, iptables — keep them on PATH.
      path = [ pkgs.rsync pkgs.kmod pkgs.util-linux pkgs.e2fsprogs pkgs.iptables ];
      serviceConfig = {
        Type = "notify";
        ExecStart = "${cfg.package}/bin/sysbox-mgr";
        TimeoutStartSec = 45;
        TimeoutStopSec = 90;
        NotifyAccess = "main";
        OOMScoreAdjust = -500;
        LimitNOFILE = "infinity";
        LimitNPROC = "infinity";
      };
    };

    systemd.services.sysbox-fs = {
      description = "sysbox-fs (part of the Sysbox container runtime)";
      partOf = [ "sysbox.service" ];
      after = [ "sysbox-mgr.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      # sysbox-fs shells out to fusermount3 to mount its FUSE filesystem under /var/lib/sysboxfs.
      path = [ pkgs.fuse3 ];
      serviceConfig = {
        Type = "notify";
        ExecStart = "${cfg.package}/bin/sysbox-fs";
        TimeoutStartSec = 10;
        TimeoutStopSec = 10;
        NotifyAccess = "main";
        OOMScoreAdjust = -500;
        LimitNOFILE = "infinity";
        LimitNPROC = "infinity";
      };
    };

    systemd.services.sysbox = {
      description = "Sysbox container runtime";
      documentation = [ "https://github.com/nestybox/sysbox" ];
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ "sysbox-mgr.service" "sysbox-fs.service" ];
      after = [ "sysbox-mgr.service" "sysbox-fs.service" ];
      before = [ "docker.service" "containerd.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = pkgs.writeShellScript "sysbox-wrapper" ''
          ${cfg.package}/bin/sysbox-runc --version
          ${cfg.package}/bin/sysbox-mgr --version
          ${cfg.package}/bin/sysbox-fs --version
          exec ${pkgs.coreutils}/bin/sleep infinity
        '';
      };
    };

    virtualisation.docker.daemon.settings = lib.mkIf cfg.registerDockerRuntime {
      runtimes.sysbox-runc.path = "${cfg.package}/bin/sysbox-runc";
    };
  };
}
