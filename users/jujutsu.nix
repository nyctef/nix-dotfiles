{ config, pkgs, ... }:

{
  home.packages = with pkgs; [
    jujutsu
  ];

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
editor = "nvim --clean"
merge-editor = "p4merge"

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

[template-aliases]
'format_timestamp(timestamp)' = 'timestamp.ago()'
log = 'zzzz | (visible_heads() & committer_date(after:"1 month ago")) | trunk()..@ | trunk()'

[aliases]
tug = ["bookmark", "move", "--from", "heads(::@- & bookmarks())", "--to", "@-"]


'';

}
