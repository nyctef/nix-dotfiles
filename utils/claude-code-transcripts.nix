{ pkgs }:

pkgs.writeShellApplication {
  name = "claude-code-transcripts";

  runtimeInputs = with pkgs; [
    uv
    # gh is needed for the --gist option
    gh
  ];

  text = ''
    # Run claude-code-transcripts in an isolated environment via uvx
    # All arguments are passed through to the tool
    uvx claude-code-transcripts "$@"
  '';
}
