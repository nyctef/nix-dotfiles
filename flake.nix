{
  description = "system config + dotfiles for nyctef";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, nixos-wsl, home-manager, ... }:

  let
    system = "x86_64-linux";

    pkgs = import nixpkgs {
      inherit system;

      config = { allowUnfree = true; };
    };

    lib = nixpkgs.lib;
  in {

    homeManagerConfigurations = {
      generic = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;

	modules = [
	    ./users/generic.nix
	];

      };
    };

    nixosConfigurations = {
      # ↓ is the hostname - needs to be parameterizable
      nixos = lib.nixosSystem {
        inherit system;

	modules = [
	  ./system/configuration.nix
	  nixos-wsl.nixosModules.default
	  {
	    # system.stateVersion = "unstable";
	    wsl.enable = true;
	  }
	];
      };
    };

  };
}
