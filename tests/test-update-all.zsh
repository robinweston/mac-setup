#!/bin/zsh
set -eu

repo_root="$(cd "${0:A:h}/.." && pwd -P)"
source "$repo_root/dotfiles/.zsh/gtr-helpers.zsh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/git-update.XXXXXX")"
test_root="${test_root:A}"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"
}

repository_root="$test_root/git"
repository_a="$repository_root/team/repository-a"
repository_a_worktree="$repository_root/worktrees/repository-a-feature"
repository_a_worktree_two="$repository_root/worktrees/repository-a-feature-two"
repository_a_stale_worktree="$repository_root/worktrees/repository-a-stale"
mkdir -p "$repository_a" "${repository_a_worktree:h}"

git init -q "$repository_a"
git -C "$repository_a" -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.com \
    commit --allow-empty -qm initial
git -C "$repository_a" worktree add -qb feature "$repository_a_worktree"
git -C "$repository_a" worktree add -qb feature-two "$repository_a_worktree_two"
git -C "$repository_a" worktree add -qb stale "$repository_a_stale_worktree"

pull_log="$test_root/pulls.log"
prune_log="$test_root/prunes.log"
action_log="$test_root/actions.log"
parallel_log="$test_root/parallel.log"

git() {
    if [[ "${1:-}" != -C || "${3:-} ${4:-}" != "pull --rebase" ]]; then
        command git "$@"
        return $?
    fi

    local repository="${2:A}"
    print -r -- "$repository" >> "$pull_log"
    print -r -- "pull:$repository" >> "$action_log"

    case "$repository" in
        "$repository_a")
            command git -C "$repository" -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.com \
                commit --allow-empty -qm pulled
            ;;
        "$repository_a_worktree"|"$repository_a_worktree_two")
            print -r -- "start:$repository" >> "$parallel_log"
            command sleep 0.05
            print -r -- "finish:$repository" >> "$parallel_log"
            ;;
    esac
}

gtr-prune() {
    print -r -- "$PWD" >> "$prune_log"
    print -r -- "prune:$PWD" >> "$action_log"
    if [[ "$PWD" == "$repository_a" && -d "$repository_a_stale_worktree" ]]; then
        git worktree remove --force "$repository_a_stale_worktree"
    fi
}

gtr() {
    [[ "$1 $2" == "cd main" ]] || fail "unexpected gtr arguments: $*"
    print -r -- "gtr-cd-main:$PWD" >> "$action_log"
    cd "$repository_a"
}

starting_directory="$repository_a_worktree"
output_file="$test_root/git-update-output.log"
(
    cd "$starting_directory"
    git-update
    [[ "$PWD" == "$repository_a" ]] || fail "git-update did not leave the shell in the base worktree"
) > "$output_file"
output="$(<"$output_file")"

[[ "$(wc -l < "$pull_log" | tr -d ' ')" == 3 ]] || \
    fail "git-update did not pull the base and both remaining worktrees"
[[ "$(sed -n '1p' "$action_log")" == "gtr-cd-main:$repository_a_worktree" ]] || \
    fail "git-update did not use gtr cd main from the linked worktree"
[[ "$(sed -n '2p' "$action_log")" == "pull:$repository_a" ]] || \
    fail "git-update did not pull the base after changing worktrees"
[[ "$(sed -n '3p' "$action_log")" == "prune:$repository_a" ]] || \
    fail "git-update did not prune after pulling the base"
remaining_actions="$(tail -n +4 "$action_log" | sort)"
expected_remaining_actions="$(printf '%s\n' "pull:$repository_a_worktree" "pull:$repository_a_worktree_two" | sort)"
[[ "$remaining_actions" == "$expected_remaining_actions" ]] || \
    fail "git-update did not pull each remaining worktree after pruning"
[[ "$(sed -n '1,2p' "$parallel_log")" != *"finish:"* ]] || \
    fail "git-update did not start remaining worktree pulls concurrently"
[[ "$(<"$pull_log")" != *"$repository_a_stale_worktree"* ]] || \
    fail "git-update pulled a worktree removed by gtr-prune"
assert_contains "$output" "Updating $repository_a"
assert_contains "$output" "Updated: 1"
assert_contains "$output" "Already current: 2"
assert_contains "$output" "Pruned successfully: 1"
assert_contains "$output" "Updating 2 remaining worktree(s) in parallel"

usage_output="$(git-update "$repository_a" 2>&1)" && fail "git-update accepted a repository argument"
[[ "$usage_output" == "usage: git-update" ]] || \
    fail "git-update did not report usage when given an argument"
(( $+functions[update-all] == 0 )) || fail "the old update-all command is still defined"

echo "PASS: git-update uses the current worktree and moves to its base"
echo "PASS: the old update-all command was removed"
echo "PASS: git-update runs base pull, prune, then remaining worktree pulls"
echo "PASS: git-update pulls remaining worktrees in parallel"
