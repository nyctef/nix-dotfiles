{ config, pkgs, ... }:

let
  jjpr = import ../utils/jjpr.nix { inherit pkgs; };
  jjdesc = import ../utils/jjdesc.nix { inherit pkgs; };
in
{
  home.packages = with pkgs; [
    jujutsu
    jjpr
    jjdesc
  ];

  xdg.configFile."jj/config.toml".source = ./jujutsu-config.toml;

}
