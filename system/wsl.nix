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
    wsl = {
      enable = true;
      # don't include binaries from windows PATH
      interop.includePath = false;
    };

    environment.systemPackages = with pkgs; [
      wslu
      (pkgs.callPackage ../utils/wsl-toast.nix {})
    ];

  };

}
