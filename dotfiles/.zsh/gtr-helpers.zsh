_gtr_worktree_is_registered() {
    local expected_path="${1:A}" field output

    output="$(git worktree list --porcelain -z 2>/dev/null)" || return 2

    for field in "${(@0)output}"; do
        if [[ "$field" == worktree\ * && "${${field#worktree }:A}" == "$expected_path" ]]; then
            return 0
        fi
    done

    return 1
}

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
        echo "Run without --dry-run to remove"
        return 0
    fi

    # Missing registrations are often newer than Git's default expiry window.
    # They have already been identified as stale above, so expire them now and
    # confirm Git actually forgot each path before deleting or counting it.
    if [[ ${#stale_paths[@]} -gt 0 ]]; then
        echo "Pruning stale worktree metadata..."
        if ! git worktree prune --expire now; then
            echo "Failed to prune stale worktree metadata" >&2
        fi

        local registration_status
        for wt_path in "${stale_paths[@]}"; do
            if _gtr_worktree_is_registered "$wt_path"; then
                registration_status=0
            else
                registration_status=$?
            fi
            if (( registration_status == 0 )); then
                echo "Failed to remove stale worktree registration for $wt_path" >&2
                continue
            elif (( registration_status != 1 )); then
                echo "Could not verify stale worktree registration removal for $wt_path" >&2
                continue
            fi

            if [[ -d "$wt_path" ]]; then
                echo "==> Removing stale directory: ${wt_path##*/}"
                if ! rm -rf -- "$wt_path"; then
                    echo "Failed to remove $wt_path" >&2
                    continue
                fi
            fi

            echo "==> Removed stale worktree: ${wt_path##*/}"
            ((removed += 1))
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
        else
            echo "Failed to remove worktree for $branch" >&2
        fi
    done

    echo "Removed $removed worktree(s)"
}
