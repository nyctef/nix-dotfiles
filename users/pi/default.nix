{
  lib,
  config,
  pkgs,
  ...
}:

let
  waitcat = import ../../utils/waitcat.nix { inherit pkgs; };
  secretFile = ../../secrets/brave-search-api-key.age;
  hasSecret = builtins.pathExists secretFile;
in
{
  options.pi.webSearch.enable = lib.mkEnableOption "Brave web search extension for pi" // {
    default = hasSecret;
  };

  config = lib.mkMerge [
    {
      # Global agent instructions, auto-loaded by pi at session startup.
      # Same content is mounted at ~/.claude/CLAUDE.md by users/claude-code.nix.
      home.file.".pi/agent/AGENTS.md".source = ../agent-instructions.md;
    }

    (lib.mkIf config.pi.webSearch.enable {
    age.secrets.brave-search-api-key.file = secretFile;

    # Deploy the web search extension to pi's global extensions directory.
    # pi auto-discovers *.ts files in ~/.pi/agent/extensions/.
    home.file.".pi/agent/extensions/websearch.ts".source = ./websearch.ts;

    home.sessionVariables = {
      BRAVE_SEARCH_API_KEY = ''$(${waitcat}/bin/waitcat ${config.age.secrets.brave-search-api-key.path})'';
    };
    })
  ];
}
