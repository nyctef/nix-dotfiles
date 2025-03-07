# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    # inputs.agenix.nixosModules.default
  ];

  environment.systemPackages = with pkgs; [

    # this gets confusing because of https://github.com/nix-community/home-manager/issues/4060
    # going to just manually install home-manager locally for now :/
    # home-manager

  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # set fish as the default shell for users
  users.defaultUserShell = pkgs.fish;
  # we have to install it here even though it's also installed in home-manager,
  # or apparently lots of things will break
  programs.fish.enable = true;

  # disable CUPS browsed for auto printer detection due to general insecurity
  services.printing.browsed.enable = false;

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # allow running unpatched binaries that assume a link loader is at eg
  # /lib64/ld-linux-x86-64.so.2
  # https://github.com/nix-community/nix-ld
  programs.nix-ld.enable = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = lib.mkDefault "24.05"; # Did you read the comment?
}
