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
  # ~/.ssh/id_nyctef_2026. NixOS installs this under
  # /etc/ssh/authorized_keys.d/, which sshd reads alongside ~/.ssh/authorized_keys,
  # so it stays valid independently of home-manager.
  nyctefKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDFUlR/WWULw+ULRHYaieM2HyKr28qchBTzyqcICqgf8 nyctef-2026";
in

{
  imports = [
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

  # azure-common sets this to "prohibit-password" and ../configuration.nix sets
  # "no", both at normal priority, so the tie has to be broken explicitly.
  services.openssh.settings.PermitRootLogin = lib.mkForce "no";

  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  system.stateVersion = "26.05";
}
