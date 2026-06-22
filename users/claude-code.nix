{
  inputs,
  lib,
  config,
  pkgs,
  ...
}:

let
  run-claude-docker = import ../utils/run-claude-docker.nix { inherit pkgs; };
  waitcat = import ../utils/waitcat.nix { inherit pkgs; };

  # A dedicated, long-lived OAuth token for Claude running inside the docker
  # wrapper (run-claude-docker.sh). Produced once on the host with
  #   `claude setup-token`
  # then stored encrypted with
  #   `cd ~/.dotfiles && agenix -e secrets/claude-code-oauth-token.age`
  # Guarded by pathExists so the config still evaluates before the secret is
  # created. Exposed as CLAUDE_DOCKER_OAUTH_TOKEN (NOT CLAUDE_CODE_OAUTH_TOKEN)
  # so the host's own Claude keeps using its full-scope interactive login; the
  # docker wrapper maps this var to CLAUDE_CODE_OAUTH_TOKEN inside the container.
  oauthTokenSecret = ../secrets/claude-code-oauth-token.age;
  hasOauthToken = builtins.pathExists oauthTokenSecret;

  # Extract seccomp filter files from the @anthropic-ai/sandbox-runtime npm package.
  # Claude Code's sandbox uses seccomp (Linux kernel syscall filtering) to block
  # unix domain sockets, preventing sandboxed processes from escaping via local IPC.
  # The package ships pre-compiled BPF filter bytecode and a static binary to apply it.
  claude-sandbox-seccomp = pkgs.stdenv.mkDerivation {
    pname = "claude-sandbox-seccomp";
    version = "0.0.28";

    # Fetch the npm tarball directly from the registry.
    # No JS dependencies or build step needed — we just extract the pre-compiled binaries.
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@anthropic-ai/sandbox-runtime/-/sandbox-runtime-0.0.28.tgz";
      hash = "sha256-ZzJHZ5AMNXOENCtaXSt15JXQNWqYkMgkJj9euNAMat4=";
    };

    # npm tarballs contain a `package/` top-level directory; flatten it
    unpackPhase = ''
      tar xzf $src
      mv package/* .
    '';

    # Recreate the directory structure that Claude Code's hardcoded search expects:
    #   <root>/vendor/seccomp/x64/{apply-seccomp,unix-block.bpf}
    # Claude Code searches $HOME/.npm/lib/node_modules/@anthropic-ai/sandbox-runtime/
    # among other paths, so we symlink this derivation output there via home.file.
    installPhase = ''
      mkdir -p $out/vendor/seccomp/x64
      cp vendor/seccomp/x64/* $out/vendor/seccomp/x64/
      chmod +x $out/vendor/seccomp/x64/apply-seccomp
    '';
  };
in

{
  config = {
    home.sessionPath = [ "$HOME/.local/bin" ]; # `claude install` puts the cli here

    # Dedicated container OAuth token (see the `let` block above). No-op until
    # secrets/claude-code-oauth-token.age exists.
    age.secrets = lib.optionalAttrs hasOauthToken {
      claudeCodeOauthToken.file = oauthTokenSecret;
    };
    home.sessionVariables = lib.optionalAttrs hasOauthToken {
      # waitcat (not cat) because the shell may start before agenix has decrypted.
      CLAUDE_DOCKER_OAUTH_TOKEN = ''$(${waitcat}/bin/waitcat ${config.age.secrets.claudeCodeOauthToken.path})'';
    };

    home.packages = with pkgs; [
      bubblewrap
      csharp-ls
      jq
      socat
      run-claude-docker
    ];

    # Install claude via native installer if not present
    home.activation.installClaude = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -x "$HOME/.local/bin/claude" ]; then
        export PATH="${lib.makeBinPath [ pkgs.curl pkgs.coreutils ]}:$PATH"
        run ${pkgs.curl}/bin/curl -fsSL https://claude.ai/install.sh | ${pkgs.bash}/bin/bash
      fi
    '';

    # Place seccomp files where Claude Code's hardcoded search paths will find them.
    # Claude Code searches $HOME/.npm/lib/node_modules/@anthropic-ai/sandbox-runtime/
    # for vendor/seccomp/x64/{apply-seccomp,unix-block.bpf}.
    # Note: sandbox.seccomp.bpfPath/applyPath settings.json keys exist in the code but
    # are broken — _DA() doesn't pass them through to the internal config. This symlink
    # approach uses the global npm fallback search path instead.
    home.file.".npm/lib/node_modules/@anthropic-ai/sandbox-runtime".source = "${claude-sandbox-seccomp}";

    # Patch settings.json declaratively while allowing Claude Code to manage it mutably.
    # This uses a shell script to merge our declarative settings with Claude's runtime settings.
    home.activation.patchClaudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.bash}/bin/bash ${./patch-claude-settings.sh}
    '';

    # Global agent instructions for Claude Code. Same content is mounted at
    # ~/.pi/agent/AGENTS.md by users/pi/default.nix for pi.
    home.file.".claude/CLAUDE.md".source = ./agent-instructions.md;

    # Skills
    home.file.".claude/skills/pr-review-comments/SKILL.md".source = ./claude-code/pr-review-comments.md;
    home.file.".claude/skills/clone-repo-for-investigation/SKILL.md".source = ./claude-code/clone-repo-for-investigation.md;
    home.file.".claude/skills/reverse-engineer-claude-binary/SKILL.md".source = ./claude-code/reverse-engineer-claude-binary.md;
  };
}
