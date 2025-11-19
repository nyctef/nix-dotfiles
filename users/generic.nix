{
  inputs,
  lib,
  config,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.genHome;

  waitcat = import ../utils/waitcat.nix { inherit pkgs; };
in
{

  imports = [
    ./jujutsu.nix
    ./tmux.nix
    ./neovim
    ./fish
    ./dotnet.nix

    inputs.agenix.homeManagerModules.default
  ];

  options.genHome = {
    username = mkOption {
      type = types.str;
      default = "nixos";
    };
  };

  config = {
    # Home Manager needs a bit of information about you and the paths it should
    # manage.
    home.username = cfg.username;
    home.homeDirectory = "/home/${cfg.username}";

    # This value determines the Home Manager release that your configuration is
    # compatible with. This helps avoid breakage when a new Home Manager release
    # introduces backwards incompatible changes.
    #
    # You should not change this value, even if you update Home Manager. If you do
    # want to update the value, then make sure to first check the Home Manager
    # release notes.
    home.stateVersion = "24.05"; # Please read the comment before changing.

    # The home.packages option allows you to install Nix packages into your
    # environment.
    home.packages = with pkgs; [
      # # Adds the 'hello' command to your environment. It prints a friendly
      # # "Hello, world!" when run.
      # pkgs.hello

      # # It is sometimes useful to fine-tune packages, for example, by applying
      # # overrides. You can do that directly here, just don't forget the
      # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
      # # fonts?
      # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

      # # You can also create simple shell scripts directly inside your
      # # configuration. For example, this adds a command 'my-hello' to your
      # # environment:
      # (pkgs.writeShellScriptBin "my-hello" ''
      #   echo "Hello, ${config.home.username}!"
      # '')

      gh
      git-crypt
      gnupg
      inputs.agenix.packages.${system}.default

      inputs.ff14-utils.packages.${system}.default

      pstree
      wget
      tree

      maven
      dig

      bc

      github-copilot-cli
    ];

    # Home Manager is pretty good at managing dotfiles. The primary way to manage
    # plain files is through 'home.file'.
    home.file = {
      # # Building this configuration will create a copy of 'dotfiles/screenrc' in
      # # the Nix store. Activating the configuration will then make '~/.screenrc' a
      # # symlink to the Nix store copy.
      # ".screenrc".source = dotfiles/screenrc;

      # # You can also set the file content immediately.
      # ".gradle/gradle.properties".text = ''
      #   org.gradle.console=verbose
      #   org.gradle.daemon.idletimeout=3600000
      # '';
    };

    # Home Manager can also manage your environment variables through
    # 'home.sessionVariables'. These will be explicitly sourced when using a
    # shell provided by Home Manager. If you don't want to manage your shell
    # through Home Manager then you have to manually source 'hm-session-vars.sh'
    # located at either
    #
    #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
    #
    # or
    #
    #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
    #
    # or
    #
    #  /etc/profiles/per-user/nixos/etc/profile.d/hm-session-vars.sh
    #
    age.secrets.hello.file = ../secrets/hello.age;
    home.sessionVariables = {
      # avoid pasting agenix-encrypted secrets directly into a store file
      # the outer $(...) gets put directly into the fish init script, then
      # interpreted while fish is loading.
      # the inner ${...} gets interpolated here while nix is building.
      # so the resulting fish script ends up looking something like
      #   set -gx hello (/.../waitcat/bin/waitcat /.../agenix/hello)
      # where the agenix/hello file will have been decrypted at startup time
      # using the machine's ssh host keys. When using home-manager the shell
      # might try to start before the agenix service has fully loaded, so
      # we use waitcat instead of cat to work around the problem.
      hello = ''$(${waitcat}/bin/waitcat ${config.age.secrets.hello.path})'';
    };

    home.sessionPath = [
      # add apply-users and apply-system to the PATH
      # note we reference `self` here instead of `./bin` since if we do
      # the latter, then the bin folder gets copied by itself into the store
      "${inputs.self}/bin"
    ];

    home.file.".ssh/hm_authorized_keys" = {
      text = ''
        ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCekId/sXLRgaXZKcDzBeQyaJftBNKCXh5Hwn0KaLgbxUtCc+uJRKu9lt6eg4NegJJXc6JlJxrArd8lGXcjni4eqVzQRbRA1z01Vx1IlDJMZpoERjoWytNQ/J2MifQXlqR51kpPyU/H8kNphZ9yBAeuiZxcTySZIvijT7WELD2Raw+YMtNQKVyn93yCOuAMF9o/IdbtoesJZHcrFW+cIK3m0leNAiYpS2qZ9xo79F2CP3rn142ok5s6ts0ATtuMFR/EpeqRf9WFZIVONiewg7avi3BiJabH33djJ4RrBxXAevzevFs9UZtJqjY4XJczbWSV5nwQuPP4sh8vgkjD3PVH
      '';
      # https://github.com/nix-community/home-manager/issues/3090#issuecomment-2010891733
      # sshd prevents logins if the permissions for authorized_keys are too open
      # and if we use a home-manager file directly then it'll just be a symlink into the nix store
      onChange = ''
        rm -f ~/.ssh/authorized_keys
        cp ~/.ssh/hm_authorized_keys ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
      '';
    };

    # Let Home Manager install and manage itself.
    programs.home-manager.enable = true;

    # git stuff
    programs.git = {
      enable = true;
      extraConfig = {
        # include diff in commit message editor
        commit.verbose = true;

      };
    };
  };
}
