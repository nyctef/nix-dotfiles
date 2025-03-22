{
  inputs,
  lib,
  config,
  pkgs,
  ...
}:
let
  waitcat = import ../utils/waitcat.nix { inherit pkgs; };
in

with lib;
{
  config = {

    home.packages = with pkgs; [
      dotnet-sdk_9

    ];

    age.secrets.rgPackagingRead.file = ../secrets/rg-packaging-read.age;

    home.sessionVariables = {

      # ideally we'd use `red-gate-vsts-main-v3` to be consistent here, but fish doesn't like having dashes in variable names
      NuGetPackageSourceCredentials_red_gate_vsts_main_v3 = ''$(${waitcat}/bin/waitcat ${config.age.secrets.rgPackagingRead.path})'';
    };

    xdg.configFile."NuGet/config/rg.config".text = ''
      <?xml version="1.0" encoding="utf-8"?>

      <configuration>
        <packageSources>
          <clear />
          <add key="Public NuGet" value="https://api.nuget.org/v3/index.json" />
          <add key="red_gate_vsts_main_v3" value="https://red-gate.pkgs.visualstudio.com/_packaging/Main/nuget/v3/index.json" />
        </packageSources>
      </configuration>

    '';
    # https://learn.microsoft.com/en-us/nuget/consume-packages/configuring-nuget-behavior#on-maclinux-the-user-level-config-file-location-varies-by-tooling
    home.activation.symlinkNugetConfig = hm.dag.entryAfter [ "writeBoundary" ] ''
      run ln -sf $VERBOSE_ARG ~/.config/NuGet/ ~/.nuget/NuGet
    '';

  };
}
