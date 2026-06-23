{
  description = "system config + dotfiles for nyctef";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Pinned nixpkgs solely to source Docker 29.4.3 (the last release that
    # works with sysbox-runc 0.6.7 — 29.5+ breaks it; see nestybox/sysbox#1011).
    # Deliberately does NOT follow nixpkgs, which is on 29.5+. Drop once
    # upstream sysbox supports Docker 29.5+, then use the main nixpkgs docker.
    nixpkgs-docker.url = "github:nixos/nixpkgs/8e4a6e1b8b11b3c809db563aaa6f8015d7aa70ac";

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

    plugins-roslyn-nvim.url = "github:seblyng/roslyn.nvim";
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

      # Buildable handle for the vendored sysbox package, using the same `pkgs`
      # (and Go toolchain) the NixOS module builds it with — so vendorHashes
      # computed here match. Build with `--keep-going` to surface all three
      # component vendorHashes in one run. Safe to keep around for iteration.
      packages.${system}.sysbox = pkgs.callPackage ./system/sysbox-nix/pkgs { };

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
              # Pin Docker to 29.4.3 (from the nixpkgs-docker input). sysbox-runc
              # 0.6.7 doesn't support Docker 29.5+ (which injects a "time"
              # namespace by default and changed stdio/console fd handling) —
              # containers fail to start with sysbox-runc. 29.4.3 is the last
              # known-good release (nestybox/sysbox#1011), one minor behind 29.5.
              # Revisit once upstream sysbox supports 29.x.
              virtualisation.docker.package =
                inputs.nixpkgs-docker.legacyPackages.${system}.docker_29;
              virtualisation.docker.daemon.settings = {
                hosts = [
                  "unix:///var/run/docker.sock"
                  "tcp://0.0.0.0:2375"
                ];
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
