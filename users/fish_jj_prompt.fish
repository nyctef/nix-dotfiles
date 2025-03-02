#!/usr/bin/env fish

# partly based on https://gist.github.com/hroi/d0dc0e95221af858ee129fd66251897e
function fish_jj_prompt --description 'Write out the jj prompt'

    # Is jj installed?
    if not command -sq jj
        return 1
    end

    # Are we in a jj repo?
    if not jj root --quiet &>/dev/null
        return 1
    end

    set branches (string trim (jj log --no-graph --no-pager --ignore-working-copy --color always -r 'bookmarks() & ..@' -T ' bookmarks++" "'))

    set state (string trim (jj log --no-graph --no-pager --ignore-working-copy --color always -r @ -T '
            separate(
                " ",
                coalesce(
                    surround(
                        "\"",
                        "\"",
                        if(
                            description.first_line().substr(0, 24).starts_with(description.first_line()),
                            description.first_line().substr(0, 24),
                            description.first_line().substr(0, 23) ++ "…"
                        )
                    ),
                    "nodesc"
                ),
                change_id.shortest(),
                if(conflict, "conflict"),
                if(empty, "empty"),
                if(divergent, "divergent"),
                if(hidden, "hidden"),
            )
    '))

    printf '(%s %s)' $branches $state

end
