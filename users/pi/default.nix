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

  # Anthropic API token for pi. The .age file holds the bare token; we wrap it
  # in pi's auth.json shape at activation time (see home.activation below).
  apiTokenSecret = ../../secrets/claude-api-token.age;
  hasApiToken = builtins.pathExists apiTokenSecret;
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

      # Just make settings a readonly file for now instead of trying to use
      # a patch script like the claude code equivalent. We'll lose any 
      # settings mutation done from within pi but hopefully it doesn't
      # complain as much
      home.file.".pi/agent/settings.json".source = ./settings.json;

      # Bridge extension: loads .claude/skills from the current project into pi
      # so that Claude Code project skills are available as /skill: commands.
      home.file.".pi/agent/extensions/claude-skills-bridge.ts".source = ./claude-skills-bridge.ts;
    }

    (lib.mkIf hasApiToken {
      age.secrets.claude-api-token.file = apiTokenSecret;

      # Render ~/.pi/agent/auth.json from the decrypted raw token. pi reads
      # auth.json (which takes priority over env vars), so the token stays out
      # of the shell environment — a global ANTHROPIC_API_KEY would be picked
      # up by Claude Code and override its subscription login. jq --arg does
      # the JSON escaping. Skips if agenix hasn't decrypted the secret yet
      # (rather than blocking activation); the next switch/login renders it.
      # After reloadSystemd so a token rotation has already re-run
      # agenix.service (which re-decrypts the secret) before we read it.
      home.activation.piAuthJson = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
        secret="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agenix/claude-api-token"
        if [ -r "$secret" ]; then
          dir="${config.home.homeDirectory}/.pi/agent"
          run mkdir -p "$dir"
          ( umask 077
            ${pkgs.jq}/bin/jq -n --arg key "$(cat "$secret")" \
              '{anthropic: {type: "api_key", key: $key}}' > "$dir/auth.json" )
        else
          warnEcho "pi auth.json not rendered: agenix secret not readable yet ($secret); will apply on next switch after agenix decrypts"
        fi
      '';
    })

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
