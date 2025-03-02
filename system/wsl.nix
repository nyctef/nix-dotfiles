# NixOS-WSL specific options are documented on the NixOS-WSL repository:
# https://github.com/nix-community/NixOS-WSL

{
  inputs,
  config,
  pkgs,
  ...
}:

{
  imports = [
    inputs.nixos-wsl.nixosModules.default
  ];

  config = {
    wsl.enable = true;

    environment.systemPackages = with pkgs; [
      wslu
    ];

  };

}
