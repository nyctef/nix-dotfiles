{
  description = "Sysbox container runtime — rootful OCI runtime that runs system containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
    in
    flake-utils.lib.eachSystem systems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages = rec {
          default = sysbox;
          sysbox = pkgs.callPackage ./pkgs { };
          sysbox-fs = pkgs.callPackage ./pkgs/sysbox-fs.nix { };
          sysbox-mgr = pkgs.callPackage ./pkgs/sysbox-mgr.nix { };
          sysbox-runc = pkgs.callPackage ./pkgs/sysbox-runc.nix { };
        };

        formatter = pkgs.nixpkgs-fmt;
      })
    // {
      nixosModules.default = import ./modules/sysbox.nix self;
      nixosModules.sysbox = self.nixosModules.default;
    };
}
