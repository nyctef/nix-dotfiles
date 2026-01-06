{
  inputs,
  lib,
  config,
  pkgs,
  ...
}:

{
  config = {
    home.packages = with pkgs; [
      csharp-ls
    ];

    # Create a local csharp-lsp plugin since the official one is incomplete
    # This goes in .claude-plugins (not .claude/plugins) for --plugin-dir to find
    home.file.".claude-plugins/csharp-lsp/.claude-plugin/plugin.json".text = builtins.toJSON {
      name = "csharp-lsp";
      version = "1.0.0";
      description = "C# language server providing code intelligence and diagnostics";
      author.name = "Local Configuration";
      lspServers = "./.lsp.json";
    };

    home.file.".claude-plugins/csharp-lsp/.lsp.json".text = builtins.toJSON {
      csharp = {
        command = "${pkgs.csharp-ls}/bin/csharp-ls";
        args = [ ];
        extensionToLanguage = {
          ".cs" = "csharp";
        };
        restartOnCrash = true;
        maxRestarts = 5;
      };
    };

    # Register a local marketplace and enable the plugin
    home.file.".claude/settings.json".text = builtins.toJSON {
      extraKnownMarketplaces = {
        local-plugins = {
          source = {
            source = "directory";
            path = "${config.home.homeDirectory}/.claude-plugins";
          };
        };
      };
      enabledPlugins = {
        "csharp-lsp@local-plugins" = true;
      };
    };
  };
}
