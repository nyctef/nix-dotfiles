# Azure VM deployed with nixos-anywhere. No hardware-configuration.nix here:
# the disk layout comes from disk-config.nix and the rest of the hardware is
# Hyper-V, described by nixpkgs' azure-common profile.

{
  inputs,
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  # Same key as users/generic.nix installs into ~/.ssh/authorized_keys.
  nyctefKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCekId/sXLRgaXZKcDzBeQyaJftBNKCXh5Hwn0KaLgbxUtCc+uJRKu9lt6eg4NegJJXc6JlJxrArd8lGXcjni4eqVzQRbRA1z01Vx1IlDJMZpoERjoWytNQ/J2MifQXlqR51kpPyU/H8kNphZ9yBAeuiZxcTySZIvijT7WELD2Raw+YMtNQKVyn93yCOuAMF9o/IdbtoesJZHcrFW+cIK3m0leNAiYpS2qZ9xo79F2CP3rn142ok5s6ts0ATtuMFR/EpeqRf9WFZIVONiewg7avi3BiJabH33djJ4RrBxXAevzevFs9UZtJqjY4XJczbWSV5nwQuPP4sh8vgkjD3PVH";
in

{
  imports = [
    (modulesPath + "/virtualisation/azure-common.nix")
    inputs.disko.nixosModules.disko
    ./disk-config.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # azure-common defaults the hostname to "" so waagent can supply it from the
  # instance metadata; we want a stable name instead.
  networking.hostName = "nyc-08";
  time.timeZone = "Europe/London";
  i18n.defaultLocale = "en_US.UTF-8";

  users.users.nyctef = {
    isNormalUser = true;
    description = "Mark Jordan";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ nyctefKey ];
  };

  # No passwords are set on this machine; it's SSH-key access only.
  security.sudo.wheelNeedsPassword = false;

  # nixos-anywhere installs over SSH as root, and root is still how the machine
  # is reachable if the nyctef account or home-manager breaks. azure-common
  # already relaxes this to "prohibit-password"; ../configuration.nix sets "no",
  # so the conflict has to be broken explicitly.
  services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
  users.users.root.openssh.authorizedKeys.keys = [ nyctefKey ];

  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  system.stateVersion = "26.05";
}
