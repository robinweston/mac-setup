_gtr_parse_bitbucket_url() {
    local pr_pattern='^https?://bitbucket\.org/([^/]+)/([^/]+)/pull-requests/([[:digit:]]+)([/?#].*)?$'
    local branch_pattern='^https?://bitbucket\.org/([^/]+)/([^/]+)/branch/([^?#]+)([?#].*)?$'

    if [[ "$1" =~ $pr_pattern ]]; then
        printf 'pull-request\t%s\t%s\t%s\n' "${match[1]}" "${match[2]}" "${match[3]}"
    elif [[ "$1" =~ $branch_pattern ]]; then
        printf 'branch\t%s\t%s\t%s\n' "${match[1]}" "${match[2]}" "${match[3]}"
    else
        return 1
    fi
}

_gtr_repository_identity() {
    local repository="${1:-.}"
    local remote_url

    remote_url="$(git -C "$repository" remote get-url origin 2>/dev/null)" || return 1
    remote_url="${remote_url%.git}"
    [[ "$remote_url" =~ '[/:]([^/]+)/([^/]+)$' ]] || return 1
    printf '%s/%s\n' "${match[1]}" "${match[2]}"
}

_gtr_find_base_repository() {
    local repository_root="$1" expected_identity="$2"
    local git_directory candidate identity
    local -a matches=()

    [[ -d "$repository_root" ]] || {
        echo "repository root does not exist: $repository_root" >&2
        return 1
    }

    while IFS= read -r -d $'\0' git_directory; do
        candidate="${git_directory:h}"
        identity="$(_gtr_repository_identity "$candidate" 2>/dev/null || true)"
        [[ "$identity" == "$expected_identity" ]] && matches+=("$candidate")
    done < <(find "$repository_root" -maxdepth 5 -type d -name .git -print0 2>/dev/null)

    if (( ${#matches} == 0 )); then
        echo "no base checkout under $repository_root has origin repository '$expected_identity'" >&2
        return 1
    fi
    if (( ${#matches} > 1 )); then
        echo "multiple base checkouts under $repository_root have origin repository '$expected_identity':" >&2
        printf '  %s\n' "${matches[@]}" >&2
        return 1
    fi

    printf '%s\n' "${matches[1]}"
}

_gtr_branch_from_bitbucket_pr() {
    local workspace="$1" repo="$2" pr_number="$3"
    local pr_json branch

    if ! command -v bkt >/dev/null 2>&1; then
        echo "bkt is not installed" >&2
        return 1
    fi

    if ! pr_json="$(bkt pr view "$pr_number" --workspace "$workspace" --repo "$repo" --json 2>&1)" ||
       [[ -z "$pr_json" ]]; then
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

    printf '%s\n' "${branch#refs/heads/}"
}

_gtr_fetch_origin_for_branch_check() {
    if ! git fetch origin --prune; then
        echo "could not fetch origin; branch existence cannot be verified" >&2
        return 1
    fi
}

_gtr_ensure_shell_integration() {
    local init_file="${XDG_CACHE_HOME:-$HOME/.cache}/gtr/init-gtr.zsh"
    local integration_status added_compdef=0

    # `gtr` is a shell function, not the git-gtr executable. Non-interactive
    # callers such as PR Monitor do not load .zshrc, so initialize it here.
    (( $+functions[gtr] )) && return 0

    # The generated integration registers completions after defining `gtr`.
    # `compdef` is unavailable before compinit runs and is unnecessary here.
    if (( ! $+functions[compdef] )); then
        compdef() { return 0 }
        added_compdef=1
    fi

    if [[ -r "$init_file" ]]; then
        source "$init_file" && integration_status=0 || integration_status=$?
    else
        eval "$(git gtr init zsh)" && integration_status=0 || integration_status=$?
    fi

    (( added_compdef )) && unfunction compdef
    (( integration_status == 0 )) || return $integration_status

    (( $+functions[gtr] )) || {
        echo "could not initialize the gtr shell integration" >&2
        return 1
    }
}

_gtr_branch_has_worktree() {
    git worktree list --porcelain | grep -Fqx "branch refs/heads/$1"
}

_gtr_open_remote_branch() {
    local branch="$1"
    shift
    _gtr_ensure_shell_integration || return $?
    _gtr_fetch_origin_for_branch_check || return $?

    if ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        echo "remote branch origin/$branch does not exist" >&2
        return 1
    fi

    if _gtr_branch_has_worktree "$branch"; then
        echo "Using existing worktree for $branch"
        gtr cd "$branch" || return $?
        open -a /Applications/ChatGPT.app .
        return $?
    fi

    echo "Creating worktree for existing branch $branch"
    gtr new --cd "$branch" "$@" --track remote --no-fetch || return $?
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

_gtr_create_local_branch() {
    local branch="$1"
    shift
    _gtr_ensure_shell_integration || return $?
    _gtr_fetch_origin_for_branch_check || return $?

    if git show-ref --verify --quiet "refs/heads/$branch" ||
       git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        echo "branch '$branch' already exists" >&2
        return 1
    fi

    gtr new --cd "$branch" "$@" --track none --no-fetch || return $?

    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || return $?
    git gtr editor "$branch"
}

function gtr-new {
    local target kind workspace repo value url_fields repository_identity base_repository
    local branch issue_key gtr_status
    local start_directory="$PWD"
    local repository_root="${GTR_REPOSITORY_ROOT:-$HOME/git}"

    if [[ $# -lt 1 || "$1" == -* ]]; then
        echo "usage: gtr-new <branch-or-bitbucket-or-jira-url> [options]" >&2
        return 1
    fi

    target="$1"
    if url_fields="$(_gtr_parse_bitbucket_url "$target")"; then
        IFS=$'\t' read -r kind workspace repo value <<< "$url_fields"
        repository_identity="$workspace/$repo"
        base_repository="$(_gtr_find_base_repository "$repository_root" "$repository_identity")" || return $?

        if [[ "$kind" == pull-request ]]; then
            branch="$(_gtr_branch_from_bitbucket_pr "$workspace" "$repo" "$value")" || return $?
        else
            branch="${value#refs/heads/}"
        fi

        cd -- "$base_repository" || return $?
        _gtr_open_remote_branch "$branch" "${@:2}"
        gtr_status=$?

        if (( gtr_status != 0 )) && [[ "$PWD" == "$base_repository" ]]; then
            cd -- "$start_directory" || return $?
        fi
        return $gtr_status
    fi

    branch="$target"
    if issue_key="$(_gtr_jira_issue_key_from_url "$target")"; then
        git rev-parse --show-toplevel >/dev/null 2>&1 || {
            echo "a Jira URL requires running gtr-new inside a Git worktree" >&2
            return 1
        }
        branch="$(_gtr_branch_from_jira_issue "$issue_key")" || return $?
        echo "Using branch name: $branch"
    fi

    _gtr_create_local_branch "$branch" "${@:2}"
}

# URLs commonly contain `?`, which Zsh otherwise treats as glob syntax before
# gtr-new has a chance to parse them.
alias gtr-new='noglob gtr-new'

_gtr_update_display_path() {
    local display_target="$1"

    if [[ "$display_target" == "$HOME" ]]; then
        printf '~\n'
    elif [[ "$display_target" == "$HOME"/* ]]; then
        printf '~/%s\n' "${display_target#$HOME/}"
    else
        printf '%s\n' "$display_target"
    fi
}

gtr-update() {
    setopt localoptions nobgnice

    local repository worktree base_worktree field output_file current_branch
    local branch before_head after_head pull_output prune_output reason display
    local index pull_status prune_status
    local -A seen_worktrees=()
    local -a worktrees=() pids=() output_files=() branches=() before_heads=() displays=()
    local -a updated=() unchanged=() failed=()
    local -a prune_succeeded=() prune_failed=()

    if (( $# != 0 )); then
        echo "usage: gtr-update" >&2
        return 1
    fi

    repository="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "gtr-update must be run inside a Git worktree" >&2
        return 1
    }
    current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$current_branch" == main ]]; then
        cd -- "$repository" || return $?
    else
        gtr cd main || return $?
    fi
    base_worktree="${PWD:A}"

    echo "Updating $(_gtr_update_display_path "$base_worktree")..."
    worktree="$base_worktree"
    display="$(_gtr_update_display_path "$worktree")"
    branch="$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [[ -n "$branch" ]] || branch="detached"
    before_head="$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null || true)"

    printf '  %s [%s] ... ' "$display" "$branch"
    if pull_output="$(git -C "$worktree" pull --rebase 2>&1)"; then
        pull_status=0
    else
        pull_status=$?
    fi
    after_head="$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null || true)"

    if (( pull_status != 0 )); then
        reason="${pull_output%%$'\n'*}"
        [[ -n "$reason" ]] || reason="git pull --rebase exited with status $pull_status"
        failed+=("$display [$branch] — $reason")
        echo "FAILED"
    elif [[ "$before_head" != "$after_head" ]]; then
        updated+=("$display [$branch] — ${before_head[1,8]:-unborn} -> ${after_head[1,8]:-unknown}")
        echo "updated"
    else
        unchanged+=("$display [$branch]")
        echo "already current"
    fi

    display="$(_gtr_update_display_path "$base_worktree")"
    printf '  Pruning %s ... ' "$display"
    if prune_output="$(cd -- "$base_worktree" && gtr-prune 2>&1)"; then
        prune_status=0
    else
        prune_status=$?
    fi

    if (( prune_status == 0 )); then
        prune_succeeded+=("$display")
        echo "done"
    else
        reason="${prune_output%%$'\n'*}"
        [[ -n "$reason" ]] || reason="gtr-prune exited with status $prune_status"
        prune_failed+=("$display — $reason")
        echo "FAILED"
    fi

    # Query Git again after pruning and update only the worktrees that are
    # still registered and present. The base checkout was already updated.
    while IFS= read -r -d $'\0' field; do
        [[ "$field" == worktree\ * ]] || continue
        worktree="${field#worktree }"
        [[ -d "$worktree" ]] || continue
        repository="$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null)" || continue
        repository="${repository:A}"
        [[ "$repository" == "$base_worktree" ]] && continue
        seen_worktrees[$repository]=1
    done < <(git -C "$base_worktree" worktree list --porcelain -z 2>/dev/null)
    worktrees=("${(@kon)seen_worktrees}")

    if (( ${#worktrees} > 0 )); then
        echo "Updating ${#worktrees} remaining worktree(s) in parallel..."
    fi

    # Pull independent worktrees concurrently. Each job gets its own output
    # file so failures can still be attributed and summarized deterministically.
    for worktree in "${worktrees[@]}"; do
        display="$(_gtr_update_display_path "$worktree")"
        branch="$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        [[ -n "$branch" ]] || branch="detached"
        before_head="$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null || true)"
        output_file="$(mktemp "${TMPDIR:-/tmp}/gtr-update.XXXXXX")" || {
            echo "could not create temporary output file" >&2
            return 1
        }

        displays+=("$display")
        branches+=("$branch")
        before_heads+=("$before_head")
        output_files+=("$output_file")
        git -C "$worktree" pull --rebase >| "$output_file" 2>&1 &
        pids+=("$!")
    done

    for (( index = 1; index <= ${#worktrees}; index += 1 )); do
        worktree="${worktrees[$index]}"
        display="${displays[$index]}"
        branch="${branches[$index]}"
        before_head="${before_heads[$index]}"
        output_file="${output_files[$index]}"

        printf '  %s [%s] ... ' "$display" "$branch"
        if wait "${pids[$index]}"; then
            pull_status=0
        else
            pull_status=$?
        fi
        pull_output="$(<"$output_file")"
        rm -f -- "$output_file"
        after_head="$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null || true)"

        if (( pull_status != 0 )); then
            reason="${pull_output%%$'\n'*}"
            [[ -n "$reason" ]] || reason="git pull --rebase exited with status $pull_status"
            failed+=("$display [$branch] — $reason")
            echo "FAILED"
        elif [[ "$before_head" != "$after_head" ]]; then
            updated+=("$display [$branch] — ${before_head[1,8]:-unborn} -> ${after_head[1,8]:-unknown}")
            echo "updated"
        else
            unchanged+=("$display [$branch]")
            echo "already current"
        fi
    done

    echo ""
    echo "Update report"
    echo "  Updated: ${#updated}"
    (( ${#updated} > 0 )) && printf '    %s\n' "${updated[@]}"
    echo "  Already current: ${#unchanged}"
    (( ${#unchanged} > 0 )) && printf '    %s\n' "${unchanged[@]}"
    echo "  Failed: ${#failed}"
    (( ${#failed} > 0 )) && printf '    %s\n' "${failed[@]}"
    echo "  Pruned successfully: ${#prune_succeeded}"
    (( ${#prune_succeeded} > 0 )) && printf '    %s\n' "${prune_succeeded[@]}"
    echo "  Prune failed: ${#prune_failed}"
    (( ${#prune_failed} > 0 )) && printf '    %s\n' "${prune_failed[@]}"

    # Individual failures are fully reported but do not make the batch stop or
    # leave an interactive shell with a failing status.
    return 0
}

_gtr_prune_archive_codex_threads() {
    local project_path="$1" dry_run="${2:-0}"
    local -a args=(projects archive-threads "$project_path")

    if ! command -v codex-desktop-cli >/dev/null 2>&1; then
        echo "Warning: codex-desktop-cli is unavailable; Codex task archival was skipped for $project_path" >&2
        return 0
    fi

    [[ "$dry_run" -eq 1 ]] && args+=(--dry-run)
    if ! codex-desktop-cli "${args[@]}"; then
        echo "Warning: worktree removal succeeded, but Codex task archival failed for $project_path" >&2
    fi
    return 0
}

gtr-prune() {
    local dry_run=0 removed=0 is_first=1
    local wt_path branch wt_status upstream
    local -a prune_branches
    local -a prune_paths
    local -a stale_paths

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n) dry_run=1; shift ;;
            *) echo "usage: gtr-prune [--dry-run|-n]" >&2; return 1 ;;
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
        prune_paths+=("$wt_path")
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
        echo "Codex task archival plan:"
        for wt_path in "${prune_paths[@]}" "${stale_paths[@]}"; do
            _gtr_prune_archive_codex_threads "$wt_path" 1
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
                if rm -rf "$wt_path"; then
                    ((removed += 1))
                    _gtr_prune_archive_codex_threads "$wt_path"
                else
                    echo "Failed to remove $wt_path" >&2
                fi
            else
                ((removed += 1))
                _gtr_prune_archive_codex_threads "$wt_path"
            fi
        done
    fi

    # Remove worktrees whose upstream is gone
    local index
    for (( index = 1; index <= ${#prune_branches[@]}; index++ )); do
        branch="${prune_branches[$index]}"
        wt_path="${prune_paths[$index]}"
        echo "==> Removing worktree: $branch"
        if git gtr rm "$branch" --delete-branch --force --yes; then
            ((removed += 1))
            _gtr_prune_archive_codex_threads "$wt_path"
        else
            echo "Failed to remove worktree for $branch" >&2
        fi
    done

    echo "Removed $removed worktree(s)"
}
