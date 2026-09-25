{ inputs, config, ... }:

{
  imports = [
    inputs.agenix.nixosModules.default
    inputs.sweetiebot.nixosModules.default
  ];

  # contains: SB_JID, SB_CHATROOM, SB_PASSWORD, SB_NICKNAME, SB_PG_DB and SB_APPINSIGHTS_KEY
  age.secrets.sweetiebot-env.file = ../../secrets/sweetiebot-env.age;

  services.sweetiebot = {
    enable = true;
    environmentFile = config.age.secrets.sweetiebot-env.path;
  };

}
