{
  config,
  lib,
  inputs,
  ...
}:
let
  utils = inputs.nixCats.utils;
in
{
  imports = [
    inputs.nixCats.homeModule
  ];
  config = {
    # this value, nixCats is the defaultPackageName you pass to mkNixosModules
    # it will be the namespace for your options.
    nixCats = {
      enable = true;
      nixpkgs_version = inputs.nixpkgs;
      # this will add the overlays from ./overlays and also,
      # add any plugins in inputs named "plugins-pluginName" to pkgs.neovimPlugins
      # It will not apply to overall system, just nixCats.
      addOverlays = # (import ./overlays inputs) ++
        [
          (utils.standardPluginOverlay inputs)
        ];
      # see the packageDefinitions below.
      # This says which of those to install.
      packageNames = [ "myHomeModuleNvim" ];

      luaPath = "${./.}";

      # the .replace vs .merge options are for modules based on existing configurations,
      # they refer to how multiple categoryDefinitions get merged together by the module.
      # for useage of this section, refer to :h nixCats.flake.outputs.categories
      categoryDefinitions.replace = (
        {
          pkgs,
          settings,
          categories,
          extra,
          name,
          mkNvimPlugin,
          ...
        }@packageDef:
        {
          lspsAndRuntimeDeps = with pkgs; {
            general = {
              telescope = [
                ripgrep
                fzf
              ];
            };
            csharp = [
              roslyn-ls
            ];
          };
          startupPlugins = {
            general = with pkgs.vimPlugins; {
              tpope = [
                vim-surround
              ];

              telescope = [
                telescope-nvim
              ];
            };
            csharp = with pkgs.vimPlugins; [
              roslyn-nvim
            ];
            # themer = with pkgs; [
            #   # you can even make subcategories based on categories and settings sets!
            #   (builtins.getAttr packageDef.categories.colorscheme {
            #       "onedark" = onedark-vim;
            #       "catppuccin" = catppuccin-nvim;
            #       "catppuccin-mocha" = catppuccin-nvim;
            #       "tokyonight" = tokyonight-nvim;
            #       "tokyonight-day" = tokyonight-nvim;
            #     }
            #   )
            # ];
          };
          optionalPlugins = {
            general = [ ];
          };
          # shared libraries to be added to LD_LIBRARY_PATH
          # variable available to nvim runtime
          sharedLibraries = {
            general = with pkgs; [
              # libgit2
            ];
          };
          environmentVariables = {
            test = {
              CATTESTVAR = "It worked!";
            };
          };
          extraWrapperArgs = {
            test = [
              ''--set CATTESTVAR2 "It worked again!"''
            ];
          };
          # lists of the functions you would have passed to
          # python.withPackages or lua.withPackages

          # get the path to this python environment
          # in your lua config via
          # vim.g.python3_host_prog
          # or run from nvim terminal via :!<packagename>-python3
          extraPython3Packages = {
            test = (_: [ ]);
          };
          # populates $LUA_PATH and $LUA_CPATH
          extraLuaPackages = {
            test = [ (_: [ ]) ];
          };
        }
      );

      # see :help nixCats.flake.outputs.packageDefinitions
      packageDefinitions.replace = {
        # These are the names of your packages
        # you can include as many as you wish.
        myHomeModuleNvim =
          { pkgs, ... }:
          {
            # they contain a settings set defined above
            # see :help nixCats.flake.outputs.settings
            settings = {
              # temporary setting: stop nixCats from managing the config dir
              # instead we create a symlink from ~/.config/nvim/ pointing at
              # this folder for faster iteration without having to do a
              # home-manager rebuild for every change (nixCats still manages
              # installing plugins, though)
              wrapRc = false;
              # IMPORTANT:
              # your alias may not conflict with your other packages.
              aliases = [
                "vim"
                "nvim"
              ];
              # neovim-unwrapped = inputs.neovim-nightly-overlay.packages.${pkgs.system}.neovim;
            };
            # and a set of categories that you want
            # (and other information to pass to lua)
            categories = {
              general = true;
              csharp = true;
              test = true;
              example = {
                youCan = "add more than just booleans";
                toThisSet = [
                  "and the contents of this categories set"
                  "will be accessible to your lua with"
                  "nixCats('path.to.value')"
                  "see :help nixCats"
                ];
              };
            };
          };
      };
    };

    home.sessionVariables = {
      EDITOR = "nvim";
    };
  };

}
