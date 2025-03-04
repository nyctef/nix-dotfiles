{
  ...
}:
{
  config = {
    # install fish, and tell HM to manage it (set session variables etc)
    programs.fish.enable = true;
    programs.fish.shellInit = "
      set -U fish_features qmark-noglob
    ";
    xdg.configFile."fish" = {
      source = ./.;
      recursive = true;
    };
  };
}
