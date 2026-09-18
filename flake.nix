{
  description = "system config + dotfiles for nyctef";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Pinned nixpkgs solely to source Docker 29.4.3 (the last release that
    # works with sysbox-runc 0.6.7 — 29.5+ breaks it; see nestybox/sysbox#1011).
    # Deliberately does NOT follow nixpkgs, which is on 29.5+. Drop once
    # upstream sysbox supports Docker 29.5+, then use the main nixpkgs docker.
    nixpkgs-docker.url = "github:nixos/nixpkgs/8e4a6e1b8b11b3c809db563aaa6f8015d7aa70ac";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    nixCats.url = "github:BirdeeHub/nixCats-nvim";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

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

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;

          config = {
            allowUnfree = true;
          };

          overlays = [
            (import ./overlays/dotnet.nix)
            (import ./overlays/jujutsu.nix)
          ];
        };

      pkgs = mkPkgs system;

      lib = nixpkgs.lib;
    in
    {

      packages.${system} = {
        # Buildable handle for the vendored sysbox package, using the same `pkgs`
        # (and Go toolchain) the NixOS module builds it with — so vendorHashes
        # computed here match. Build with `--keep-going` to surface all three
        # component vendorHashes in one run. Safe to keep around for iteration.
        sysbox = pkgs.callPackage ./system/sysbox-nix/pkgs { };

        # Buildable handle for the overlaid jujutsu (see overlays/jujutsu.nix), so
        # the cargo vendor hash can be refreshed with a plain `nix build .#jujutsu`.
        jujutsu = pkgs.jujutsu;
      };

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
        "nyctef@nyc-08" = home-manager.lib.homeManagerConfiguration {
          # nyc-08 is an Azure Ampere instance, not x86_64 like the others.
          pkgs = mkPkgs "aarch64-linux";

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
            ./system/tachikoma/configuration.nix
          ];

          specialArgs = { inherit inputs; };
        };
        nyc-08 = lib.nixosSystem {
          system = "aarch64-linux";

          modules = [
            ./system/configuration.nix
            ./system/nyc-08/configuration.nix
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
