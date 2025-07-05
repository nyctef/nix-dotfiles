{
  description = "system config + dotfiles for nyctef";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    nixCats.url = "github:BirdeeHub/nixCats-nvim";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    neovim-nightly-overlay.url = "github:nix-community/neovim-nightly-overlay";
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
            {
              virtualisation.docker.enable = true;
              virtualisation.docker.daemon.settings = {
                hosts = [
                  "unix:///var/run/docker.sock"
                  "tcp://0.0.0.0:2375"
                ];
              };
              users.users.nixos.extraGroups = [ "docker" ];

              networking.hostName = "tachikoma";
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
