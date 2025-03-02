{
  inputs,
  config,
  pkgs,
  ...
}:

{

  config = {
    services.jellyfin.enable = true;
    services.jellyfin.openFirewall = true;
  };

}
