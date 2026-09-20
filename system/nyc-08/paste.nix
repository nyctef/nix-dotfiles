{ inputs, ... }:

{
  imports = [
    inputs.qpaste.nixosModules.default
  ];

  services.qpaste = {
    enable = true;
    addr = "127.0.0.1:8002";
    baseUrl = "https://paste.nyctef.com";
  };

  services.caddy.virtualHosts."paste.nyctef.com" = {
    extraConfig = ''
      reverse_proxy localhost:8002
    '';
  };
}
