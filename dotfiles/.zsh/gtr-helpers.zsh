_gtr_pr_number_from_arg() {
    local pattern='^https?://bitbucket\.org/[^/]+/[^/]+/pull-requests/([[:digit:]]+)([/?#].*)?$'

    if [[ "$1" =~ '^[[:digit:]]+$' ]]; then
        printf '%s\n' "$1"
        return 0
    fi

    [[ "$1" =~ $pattern ]] || return 1
    printf '%s\n' "${match[1]}"
}

gtrpr() {
    local branch workspace repo remote_url pr_number

    if [[ $# -ne 1 ]]; then
        echo "usage: gtrpr <pr-number-or-bitbucket-url>" >&2
        return 1
    fi

    if ! pr_number="$(_gtr_pr_number_from_arg "$1")"; then
        echo "invalid PR number or Bitbucket pull-request URL: $1" >&2
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
    pr_json="$(bkt pr view "$pr_number" --workspace "$workspace" --repo "$repo" --json 2>&1)"

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
        echo "could not resolve source branch for PR $pr_number" >&2
        echo "pull_request keys:" >&2
        printf '%s\n' "$pr_json" | jq '.pull_request | keys' >&2
        return 1
    fi

    branch="${branch#refs/heads/}"
    gtrbranch "$branch"
}

_gtr_fetch_origin_for_branch_check() {
    if ! git fetch origin --prune; then
        echo "could not fetch origin; branch existence cannot be verified" >&2
        return 1
    fi
}

_gtr_branch_has_worktree() {
    git worktree list --porcelain | grep -Fqx "branch refs/heads/$1"
}

gtrbranch() {
    local branch="$1"

    if [[ $# -ne 1 ]]; then
        echo "usage: gtrbranch <branch>" >&2
        return 1
    fi

    _gtr_fetch_origin_for_branch_check || return $?

    if ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        echo "remote branch origin/$branch does not exist" >&2
        return 1
    fi

    if _gtr_branch_has_worktree "$branch"; then
        echo "Using existing worktree for $branch"
        gtr cd "$branch" || return $?
        code .
        return $?
    fi

    echo "Creating worktree for existing branch $branch"
    gtr new --cd "$branch" --track remote --no-fetch || return $?
    git gtr editor "$branch"
}

_gtr_jira_issue_key_from_url() {
    local pattern='^https?://[^/]+/browse/([[:alpha:]][[:alnum:]_]*-[[:digit:]]+)([/?#].*)?$'

    [[ "$1" =~ $pattern ]] || return 1
    printf '%s\n' "${match[1]:u}"
}

_gtr_branch_from_jira_issue() {
    local issue_key="$1"
    local jira_json summary slug

    if ! command -v acli >/dev/null 2>&1; then
        echo "Cannot create a branch for Jira issue $issue_key: Atlassian CLI (acli) is not installed." >&2
        echo "Install it with:" >&2
        echo "  brew tap atlassian/homebrew-acli" >&2
        echo "  brew install acli" >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "jq is not installed" >&2
        return 1
    fi

    if ! jira_json="$(acli jira workitem view "$issue_key" --fields summary --json 2>&1)"; then
        echo "could not load Jira issue $issue_key:" >&2
        printf '%s\n' "$jira_json" >&2
        echo "If needed, authenticate with: acli jira auth login --web" >&2
        return 1
    fi

    summary="$(printf '%s\n' "$jira_json" | jq -r '.fields.summary // empty' 2>/dev/null)"
    if [[ -z "$summary" ]]; then
        echo "Jira issue $issue_key did not return a summary" >&2
        return 1
    fi

    slug="$(printf '%s\n' "$summary" |
        tr '[:upper:]' '[:lower:]' |
        sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

    if [[ -n "$slug" ]]; then
        printf '%s-%s\n' "${issue_key:l}" "$slug"
    else
        printf '%s\n' "${issue_key:l}"
    fi
}

gtrnew() {
    local branch issue_key
    local -a gtr_args

    if [[ $# -lt 1 || "$1" == -* ]]; then
        echo "usage: gtrnew <branch-or-jira-url> [options]" >&2
        return 1
    fi

    branch="$1"
    if issue_key="$(_gtr_jira_issue_key_from_url "$branch")"; then
        branch="$(_gtr_branch_from_jira_issue "$issue_key")" || return $?
        echo "Using branch name: $branch"
    fi

    gtr_args=("$@")
    gtr_args[1]="$branch"

    _gtr_fetch_origin_for_branch_check || return $?

    if git show-ref --verify --quiet "refs/heads/$branch" ||
       git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        echo "branch '$branch' already exists; use gtrbranch $branch" >&2
        return 1
    fi

    gtr new --cd "${gtr_args[@]}" --track none --no-fetch || return $?

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
