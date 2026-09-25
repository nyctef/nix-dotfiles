{ config, ... }:

{
  # contains a Tailscale auth key from https://login.tailscale.com/admin/settings/keys
  # with the relevant tags defined. Defining the tags in the key creation
  # seems to be more reliable and also automatically disables node key expiry,
  # at the cost of an extra manual step
  age.secrets.nyc-08-tailscale-authkey.file = ../../secrets/nyc-08-tailscale-authkey.age;

  services.tailscale = {
    enable = true;
    authKeyFile = config.age.secrets.nyc-08-tailscale-authkey.path;
    useRoutingFeatures = "server";
    openFirewall = true;
    extraSetFlags = [ "--advertise-connector" ];
  };
}
