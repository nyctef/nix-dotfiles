{ inputs, config, ... }:

{
  imports = [
    inputs.agenix.nixosModules.default
    inputs.sweetiebot.nixosModules.default
  ];

  # contains SB_JID, SB_PASSWORD and SB_CHATROOM
  age.secrets.sweetiebot-env.file = ../../secrets/sweetiebot-env.age;

  services.sweetiebot = {
    enable = true;
    environmentFile = config.age.secrets.sweetiebot-env.path;
    settings = {
      # peer auth over the unix socket: the service's DynamicUser is named
      # after the unit, which matches the postgres role below
      SB_PG_DB = "host=/run/postgresql dbname=sweetiebot user=sweetiebot";
    };
  };

  # the schema isn't created automatically: see bootstrap.md
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "sweetiebot" ];
    ensureUsers = [
      {
        name = "sweetiebot";
        ensureDBOwnership = true;
      }
    ];
  };

  systemd.services.sweetiebot = {
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
  };
}
