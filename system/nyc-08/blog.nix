{ inputs, pkgs, ... }:
{
  services.caddy.virtualHosts."blog.nyctef.com" = {
    extraConfig = ''
      root * ${inputs.blog-nyctef-com.packages.${pkgs.system}.default}
      file_server
    '';
  };
}
