#!/bin/zsh

# Launch a Codex Desktop project thread with only the external write access
# needed by the hook's Git workflow.
codex_project_thread() {
    local codex_bin="$1"
    local workflow="$2"
    shift 2

    local git_common_directory
    local git_directory
    git_common_directory="$(git rev-parse --path-format=absolute --git-common-dir)"
    git_directory="$(git rev-parse --path-format=absolute --git-dir)"

    local -a writable_directories=(
        "$git_common_directory"
        "$git_directory"
    )

    case "$workflow" in
        bitbucket)
            writable_directories+=(
                "$HOME/.config/bkt"
                "$HOME/Library/Application Support/bkt"
            )
            ;;
        git)
            ;;
        *)
            print -u2 -- "Codex project thread: unsupported workflow: $workflow"
            return 1
            ;;
    esac

    local -a writable_arguments=()
    local directory
    for directory in "${writable_directories[@]}"; do
        writable_arguments+=(--add-dir "$directory")
    done

    exec "$codex_bin" threads new "$@" "${writable_arguments[@]}"
}
