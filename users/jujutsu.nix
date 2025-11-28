{ config, pkgs, ... }:

let
  jjpr = import ../utils/jjpr.nix { inherit pkgs; };
in
{
  home.packages = with pkgs; [
    jujutsu
    jjpr
  ];

  xdg.configFile."jj/config.toml".source = ./jujutsu-config.toml;

}
