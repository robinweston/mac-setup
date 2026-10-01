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
    if prune_output="$(cd -- "$base_worktree" && "$HOME/.agents/skills/cleanup-worktrees/scripts/prune-missing-worktrees.py" --repo "$base_worktree" 2>&1)"; then
        prune_status=0
    else
        prune_status=$?
    fi

    if (( prune_status == 0 )); then
        prune_succeeded+=("$display")
        echo "done"
    else
        reason="${prune_output%%$'\n'*}"
        [[ -n "$reason" ]] || reason="worktree pruner exited with status $prune_status"
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
