{
  services.beszel = {
    hub = {
      enable = true;
      host = "127.0.0.1";
      port = 8001;
    };
    agent = {
      enable = true;
      environment = {
        HUB_URL = "http://localhost:8001";
      };
      # this file will need to be created manually: see bootstrap.md
      environmentFile = "/var/lib/beszel-agent/credentials";
    };
  };

  services.caddy.virtualHosts."stats.nyctef.com" = {
    extraConfig = ''
      reverse_proxy localhost:8001
    '';
  };
}
