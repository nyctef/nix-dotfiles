{
  inputs,
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  # important so that we can log in later after nix-anywhere has blatted the system :)
  nyctefKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDFUlR/WWULw+ULRHYaieM2HyKr28qchBTzyqcICqgf8 nyctef-2026";
in

{
  imports = [
    # azure-common is a builtin module for azure VMs.
    # replaces the usual hardware-configuration.nix file
    (modulesPath + "/virtualisation/azure-common.nix")
    inputs.disko.nixosModules.disko
    ./disk-config.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # azure-common defaults the hostname to "" so waagent can supply it from the
  # instance metadata; we want a stable name instead.
  networking.hostName = "nyc-08";

  # override some azure-common.nix kernel config with ARM-specific stuff
  boot.kernelParams = [
    # ttyAMA0: ARM-specific serial port
    # 115200n8: configuring the port
    "console=ttyAMA0,115200n8"
    # bring up the console as soon as possible to see any kernel issues
    "earlycon"
  ];
  time.timeZone = "Europe/London";
  i18n.defaultLocale = "en_US.UTF-8";

  users.users.nyctef = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ nyctefKey ];
  };

  # since everything is SSH keys instead of passwords
  security.sudo.wheelNeedsPassword = false;

  # since deploying from another machine (as in bin/deploy-nyc-08.sh)
  # ends up signing the build result with a different key, nyc-08 won't
  # trust a build result unless it's coming from a trusted user.
  # another way that nyctef gets root access on the box.
  #
  # TODO: there's probably a better way to accomplish this by configuring
  # a specific trusted key from the source machine (tachikoma) which might
  # be worth playing around with
  #
  # see `bootstrap.md` for an initial workaround deploying this setting
  nix.settings.trusted-users = [
    "root"
    "nyctef"
  ];

  # azure-common sets this to "prohibit-password" and ../configuration.nix sets
  # "no", both at normal priority, so the tie has to be broken explicitly.
  services.openssh.settings.PermitRootLogin = lib.mkForce "no";

  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  system.stateVersion = "26.05";
}
