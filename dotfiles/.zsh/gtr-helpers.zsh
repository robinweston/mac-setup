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
    local dry_run=0 removed=0 is_first=1
    local wt_path branch wt_status upstream
    local -a prune_branches

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n) dry_run=1; shift ;;
            *) echo "usage: gtrprune [--dry-run|-n]" >&2; return 1 ;;
        esac
    done

    [[ $dry_run -eq 1 ]] && echo "(dry run mode)"

    echo "Fetching and pruning remote refs..."
    git fetch --prune || {
        echo "git fetch --prune failed" >&2
        return 1
    }
    echo "Fetch complete"

    echo "Listing worktrees..."
    while IFS=$'\t' read -r wt_path branch wt_status; do
        if [[ $is_first -eq 1 ]]; then
            is_first=0
            continue
        fi

        [[ "$wt_status" != "ok" ]] && continue

        echo "Checking $branch..."
        upstream="$(git for-each-ref --format='%(upstream:short)' "refs/heads/$branch")"

        if [[ -z "$upstream" ]]; then
            echo "  no upstream, skipping"
            continue
        fi

        if git rev-parse --verify --quiet "refs/remotes/${upstream}^{commit}" >/dev/null 2>&1; then
            echo "  upstream $upstream still exists, skipping"
            continue
        fi

        echo "  upstream $upstream gone, marking for removal"
        prune_branches+=("$branch")
    done < <(git gtr list --porcelain)

    if [[ ${#prune_branches[@]} -eq 0 ]]; then
        echo "No worktrees to remove"
        return 0
    fi

    if [[ $dry_run -eq 1 ]]; then
        echo "Dry run — would remove ${#prune_branches[@]} worktree(s):"
        printf '  %s\n' "${prune_branches[@]}"
        echo ""
        echo "Run without --dry-run to remove"
        return 0
    fi

    for branch in "${prune_branches[@]}"; do
        echo "==> Removing worktree: $branch"
        if git gtr rm "$branch" --delete-branch --yes; then
            ((removed += 1))
        else
            echo "Failed to remove worktree for $branch" >&2
        fi
    done

    echo "Removed $removed worktree(s)"
}
