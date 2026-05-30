gtrpr() {
    local branch workspace repo remote_url

    if [[ $# -ne 1 ]]; then
        echo "usage: gtrpr <pr-number>" >&2
        return 1
    fi

    if ! command -v bkt >/dev/null 2>&1; then
        echo "bkt is not installed" >&2
        return 1
    fi

    remote_url="$(git remote get-url origin 2>/dev/null)"
    if [[ -z "$remote_url" ]]; then
        echo "could not determine origin remote URL" >&2
        return 1
    fi

    # Strip trailing .git suffix if present
    remote_url="${remote_url%.git}"

    # Extract workspace/repo from common remote URL formats:
    #   work_git:workspace/repo
    #   git@bitbucket.org:workspace/repo
    #   https://bitbucket.org/workspace/repo
    #   ssh://git@bitbucket.org/workspace/repo
    if [[ "$remote_url" =~ [:/]([^/]+)/([^/]+)$ ]]; then
        workspace="${match[1]}"
        repo="${match[2]}"
    else
        echo "could not parse workspace/repo from remote URL: $remote_url" >&2
        return 1
    fi

    local pr_json
    pr_json="$(bkt pr view "$1" --workspace "$workspace" --repo "$repo" --json 2>&1)"

    if [[ $? -ne 0 || -z "$pr_json" ]]; then
        echo "bkt pr view failed:" >&2
        echo "$pr_json" >&2
        return 1
    fi

    branch="$(printf '%s\n' "$pr_json" | jq -r '
        .pull_request.source.branch.name //
        .pull_request.fromRef.displayId //
        .pull_request.source.branchName //
        .source.branch.name //
        .fromRef.displayId //
        empty
    ')"

    if [[ -z "$branch" || "$branch" == "null" ]]; then
        echo "could not resolve source branch for PR $1" >&2
        echo "pull_request keys:" >&2
        printf '%s\n' "$pr_json" | jq '.pull_request | keys' >&2
        return 1
    fi

    branch="${branch#refs/heads/}"

    echo "Creating worktree for $branch"
    gtr new --cd "$branch" || return $?
    git gtr editor "$branch"
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
    local -a stale_paths

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

        # Handle detached/missing worktrees (branch deleted but directory remains)
        if [[ "$branch" == "(detached)" || "$wt_status" == "missing" ]]; then
            echo "Checking ${wt_path##*/}..."
            echo "  detached/missing worktree, marking for removal"
            stale_paths+=("$wt_path")
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

    if [[ ${#prune_branches[@]} -eq 0 && ${#stale_paths[@]} -eq 0 ]]; then
        echo "No worktrees to remove"
        return 0
    fi

    if [[ $dry_run -eq 1 ]]; then
        local total=$(( ${#prune_branches[@]} + ${#stale_paths[@]} ))
        echo "Dry run — would remove $total worktree(s):"
        printf '  %s\n' "${prune_branches[@]}"
        for wt_path in "${stale_paths[@]}"; do
            printf '  %s (stale)\n' "${wt_path##*/}"
        done
        echo ""
        echo "Run without --dry-run to remove"
        return 0
    fi

    # Remove stale/missing worktrees by pruning metadata and deleting directories
    if [[ ${#stale_paths[@]} -gt 0 ]]; then
        echo "Pruning stale worktree metadata..."
        git worktree prune

        for wt_path in "${stale_paths[@]}"; do
            echo "==> Removing stale directory: ${wt_path##*/}"
            if [[ -d "$wt_path" ]]; then
                rm -rf "$wt_path" && ((removed += 1)) || echo "Failed to remove $wt_path" >&2
            else
                ((removed += 1))
            fi
        done
    fi

    # Remove worktrees whose upstream is gone
    for branch in "${prune_branches[@]}"; do
        echo "==> Removing worktree: $branch"
        if git gtr rm "$branch" --delete-branch --force --yes; then
            ((removed += 1))
        else
            echo "Failed to remove worktree for $branch" >&2
        fi
    done

    echo "Removed $removed worktree(s)"
}
