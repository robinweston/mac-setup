# Interactive convenience around the executable gtr-new command. The executable
# performs all work; this function changes the current terminal's directory.
gtr-new() {
    local result worktree_path executable="$HOME/.local/bin/gtr-new"

    [[ -x "$executable" ]] || {
        print -u2 -- "gtr-new is not installed at $executable"
        return 1
    }

    result="$(command "$executable" "$@" --porcelain)" || return $?
    print -r -- "$result"
    worktree_path="$(print -r -- "$result" | awk -F $'\t' '$1 == "path" { print $2 }')"

    [[ -n "$worktree_path" && -d "$worktree_path" ]] || {
        print -u2 -- "gtr-new did not return a valid worktree path"
        return 1
    }

    cd -- "$worktree_path"
}

# URLs commonly contain `?`, which Zsh otherwise treats as glob syntax before
# gtr-new has a chance to parse them.
alias gtr-new='noglob gtr-new'
