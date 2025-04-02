{
  ...
}:
{
  config = {
    # install fish, and tell HM to manage it (set session variables etc)
    programs.fish = { 
      enable = true;
      shellInit = "
        set -U fish_features qmark-noglob
        ";
      shellAbbrs = {
        pg = "docker run -d --name pg -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:latest";
      };
    };
    xdg.configFile."fish" = {
      source = ./.;
      recursive = true;
    };
  };
}
