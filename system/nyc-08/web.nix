# Caddy terminates TLS for everything this machine serves, obtaining and
# renewing Let's Encrypt certificates on its own. Other web services should
# listen on a loopback port and get a virtualHost here that reverse_proxies to
# it, e.g.:
#
#   services.caddy.virtualHosts."thing.nyctef.com".extraConfig = ''
#     reverse_proxy localhost:8080
#   '';

{ inputs, ... }:

let
  # nyctef.com is plain files with no build step, so Caddy serves the flake
  # input's store path directly rather than proxying a backend. /i is an image
  # dump that's meant to be browsable as an index.
  site = ''
    root * ${inputs.nyctef-com}
    file_server /i/* browse
    file_server
  '';
in

{
  services.caddy = {
    enable = true;
    # Let's Encrypt sends certificate expiry warnings here.
    email = "nyctef@nyctef.com";
    openFirewall = true;

    virtualHosts."nyctef.com" = {
      serverAliases = [ "www.nyctef.com" ];
      extraConfig = site;
    };

    # Reachable before the A records point here. The http:// prefix keeps
    # automatic HTTPS off: Let's Encrypt won't certify a bare IP, and Caddy
    # would otherwise fall back to its own untrusted CA. Delete once DNS moves.
    virtualHosts."http://52.149.67.34".extraConfig = site;
  };
}
