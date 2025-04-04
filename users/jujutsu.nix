{ config, pkgs, ... }:

{
  home.packages = with pkgs; [
    jujutsu
  ];

  # TODO: maybe just extract this into a separate toml file?
  # that way we can get syntax highlighting / schema validation etc
  xdg.configFile."jj/config.toml".text = ''

    [user]
    name = "Nyctef"
    email = "nyctef@nyctef.com"

    # https://jj-vcs.github.io/jj/latest/config/#conditional-variables
    [[--scope]]
    --when.repositories = ["~/rg"]
    [--scope.user]
    name = "Mark Jordan"
    email = "mark.jordan@red-gate.com"

    [ui]
    merge-editor = "p4merge"
    default-command = ["st", "--no-pager"]
    conflict-marker-style = "git"

    [merge-tools]
    p4merge.merge-args = ["$base", "$left", "$right", "$output"]

    [templates]
    draft_commit_description = """
    concat(
      description,
      surround(
        "\nJJ: This commit contains the following changes:\n", "",
        indent("JJ:     ", diff.stat(72)),
      ),
      "\nJJ: ignore-rest\n",
      diff.git(),
    )
    """
    log = "builtin_log_oneline"

    [template-aliases]
    'format_timestamp(timestamp)' = 'timestamp.ago()'
    log = 'zzzz | (visible_heads() & committer_date(after:"1 month ago")) | trunk()..@ | trunk()'

    [aliases]
    tug = ["bookmark", "move", "--from", "heads(::@- & bookmarks())", "--to", "@-"]

    [git]
    # https://github.com/jj-vcs/jj/blob/main/docs/config.md#set-of-private-commits
    private-commits = "description(glob:'private:*')"
    # allow pushing new bookmarks without having to explicitly set --allow-new
    push-new-bookmarks = true

  '';

}
