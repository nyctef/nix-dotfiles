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

    home.activation.installCsharpLspPlugin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.claude-code}/bin/claude plugin install csharp-lsp@claude-plugins-official --scope user 2>&1 | grep -v "already installed" || true
    '';
  };
}
