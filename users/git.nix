{
  config,
  ...
}:

{
  programs.git = {
    enable = true;

    settings = {
      user = {
        name = "Nyctef";
        email = "nyctef@nyctef.com";
      };

      # include diff in commit message editor
      commit.verbose = true;

      # use global hooks directory for user-level hooks
      core.hooksPath = "${config.xdg.configHome}/git/hooks";

      # set default branch name for new repositories
      init.defaultBranch = "main";
    };

    includes = [
      {
        condition = "gitdir:~/rg/";
        contents = {
          user = {
            name = "Mark Jordan";
            email = "mark.jordan@red-gate.com";
          };
        };
      }
    ];
  };

  # git hooks
  # note: setting core.hooksPath globally means per-repo hooks won't run
  # unless you explicitly chain them from these global hooks
  xdg.configFile."git/hooks/pre-push" = {
    executable = true;
    text = ''
      #!/bin/bash
      #
      # pre-push hook: prevents pushing commits with "private:" prefix
      #
      # Hook API (from https://git-scm.com/docs/githooks#_pre_push):
      #   Arguments: $1 = remote name, $2 = remote URL
      #   stdin: lines of "<local-ref> <local-sha> <remote-ref> <remote-sha>"
      #   Exit non-zero to abort the push
      #
      # Special cases:
      #   - local-sha = 0000... means deleting a ref
      #   - remote-sha = 0000... means new branch (no existing remote ref)

      while read local_ref local_sha remote_ref remote_sha; do
          # Skip if we're deleting a ref
          if [ "$local_sha" = "0000000000000000000000000000000000000000" ]; then
              continue
          fi

          # Determine commit range to check
          if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
              # New branch - check all commits
              range="$local_sha"
          else
              # Existing branch - check new commits only
              range="$remote_sha..$local_sha"
          fi

          # Check for commits starting with "private:"
          private_commits=$(git log --format="%H %s" "$range" 2>/dev/null | grep -i "^[a-f0-9]* private:")

          if [ -n "$private_commits" ]; then
              echo "ERROR: Refusing to push commits with 'private:' prefix:"
              echo "$private_commits" | while read line; do
                  echo "  $line"
              done
              exit 1
          fi
      done

      exit 0
    '';
  };
}
