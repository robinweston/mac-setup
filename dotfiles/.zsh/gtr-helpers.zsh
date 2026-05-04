gtrpr() {
    local branch

    if [[ $# -ne 1 ]]; then
        echo "usage: gtrpr <pr-number>" >&2
        return 1
    fi

    if ! command -v bkt >/dev/null 2>&1; then
        echo "bkt is not installed" >&2
        return 1
    fi

    branch="$(
        bkt pr view "$1" --json \
            | jq -r '.source.branch.name // .fromRef.displayId // .source.branchName // empty'
    )"

    if [[ -z "$branch" || "$branch" == "null" ]]; then
        echo "could not resolve source branch for PR $1" >&2
        return 1
    fi

    branch="${branch#refs/heads/}"

    echo "Creating worktree for $branch"
    git gtr new "$branch"
}

gtrnew() {
    local branch

    gtr new --cd "$@" || return $?

    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || return $?
    git gtr editor "$branch"
}

gtrprune() {
    local repo_root current_head wt_path branch_ref branch upstream removed=0
    local -a prune_branches

    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "not in a git repository" >&2
        return 1
    }

    current_head="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 1

    echo "Pruning remote refs"
    git fetch --all --prune --quiet || {
        echo "git fetch --all --prune failed" >&2
        return 1
    }

    while IFS= read -r line; do
        if [[ "$line" == worktree\ * ]]; then
            wt_path="${line#worktree }"
            branch_ref=""
            continue
        fi

        if [[ "$line" == branch\ refs/heads/* ]]; then
            branch_ref="${line#branch }"
            branch="${branch_ref#refs/heads/}"

            if [[ "$wt_path" == "$repo_root" || "$branch" == "$current_head" ]]; then
                continue
            fi

            upstream="$(git for-each-ref --format='%(upstream:short)' "$branch_ref")"

            if git merge-base --is-ancestor "$branch_ref" HEAD 2>/dev/null; then
                prune_branches+=("$branch")
                continue
            fi

            if [[ -n "$upstream" ]]; then
                git rev-parse --verify --quiet "refs/remotes/$upstream^{commit}" >/dev/null || prune_branches+=("$branch")
            else
                git rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}" >/dev/null || prune_branches+=("$branch")
            fi
        fi
    done < <(git worktree list --porcelain)

    if [[ ${#prune_branches[@]} -eq 0 ]]; then
        echo "No merged or remote-deleted PR worktrees to remove"
        return 0
    fi

    for branch in "${prune_branches[@]}"; do
        echo "Removing worktree for $branch"
        if git gtr rm "$branch" --yes; then
            ((removed += 1))
        else
            echo "Failed to remove worktree for $branch" >&2
        fi
    done

    echo "Removed $removed worktree(s)"
}
