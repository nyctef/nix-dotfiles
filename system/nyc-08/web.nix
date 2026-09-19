{ inputs, ... }:
{
  services.caddy = {
    enable = true;
    # https://caddyserver.com/docs/caddyfile/options
    # CAs may send notifications about any problems here. May occasionally get
    # incorrect expiry emails if Caddy decides to switch issuers.
    email = "nyctef@nyctef.com";
    openFirewall = true;

    virtualHosts."nyctef.com" = {
      serverAliases = [ "www.nyctef.com" ];
      extraConfig = ''
        root * ${inputs.nyctef-com}
        file_server /i/* browse
        file_server
      '';
    };
  };
}
