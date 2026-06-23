{
  description = "system config + dotfiles for nyctef";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    nixCats.url = "github:BirdeeHub/nixCats-nvim";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    ff14-utils.url = "github:nyctef/ff14-utils";
    ff14-utils.inputs.nixpkgs.follows = "nixpkgs";

    nugetui.url = "github:nyctef/nugetui";
    nugetui.inputs.nixpkgs.follows = "nixpkgs";

    ticket.url = "github:wedow/ticket";
    ticket.flake = false;

    # pin to PR #308 fix for source-generated file BufReadCmd assert
    plugins-roslyn-nvim.url = "github:molostovvs/roslyn.nvim/fix-source-generated-bufs";
    plugins-roslyn-nvim.flake = false;
  };

  outputs =
    {
      nixpkgs,
      nixos-wsl,
      home-manager,
      ...
    }@inputs:

    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;

        config = {
          allowUnfree = true;
        };

        overlays = [
          (import ./overlays/dotnet.nix)
        ];
      };

      lib = nixpkgs.lib;
    in
    {

      homeConfigurations = {
        "nixos@tachikoma" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;

          modules = [
            ./users/generic.nix
            {
              genHome.username = "nixos";
            }
          ];

          extraSpecialArgs = { inherit inputs; };
        };
        "nyctef@logikoma" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;

          modules = [
            ./users/generic.nix
            {
              genHome.username = "nyctef";
            }
          ];

          extraSpecialArgs = { inherit inputs; };
        };
        "root@codespace" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;

          modules = [
            ./users/generic.nix
            {
              genHome.username = "root";
            }
	    {
                # TODO: could probably do this for username as well instead of a custom option?
		home.homeDirectory = lib.mkForce "/root";
	    }
          ];

          extraSpecialArgs = { inherit inputs; };
        };
      };

      nixosConfigurations = {
        tachikoma = lib.nixosSystem {
          inherit system;

          modules = [
            ./system/configuration.nix
            ./system/wsl.nix
            # Vendored sysbox runtime (see system/sysbox-nix/). The module is a
            # function-of-flake; we apply it with a minimal stub that just
            # supplies the package built from our own nixpkgs (Option B —
            # direct import, no extra flake input). See system/sysbox-nix/README.md.
            (import ./system/sysbox-nix/modules/sysbox.nix {
              packages.${system}.sysbox = pkgs.callPackage ./system/sysbox-nix/pkgs { };
            })
            {
              virtualisation.docker.enable = true;
              virtualisation.docker.daemon.settings = {
                hosts = [
                  "unix:///var/run/docker.sock"
                  "tcp://0.0.0.0:2375"
                ];
                features = {
                  # Docker 29.5.0+ gives each container a private "time"
                  # namespace by default (virtualizes CLOCK_MONOTONIC/BOOTTIME,
                  # not wall-clock). sysbox-runc 0.6.7 doesn't support it and
                  # fails to start containers, so disable it daemon-wide.
                  # Remove once upstream sysbox handles the namespace.
                  "time-namespaces" = false;
                };
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
            }
          ];

          specialArgs = { inherit inputs; };
        };
        logikoma = lib.nixosSystem {
          inherit system;

          modules = [
            ./system/configuration.nix
            ./system/logikoma/configuration.nix
            {
              networking.hostName = "logikoma";
            }
          ];

          specialArgs = { inherit inputs; };
        };
      };

      formatter."${system}" = nixpkgs.legacyPackages."${system}".nixfmt-rfc-style;

    };
}
