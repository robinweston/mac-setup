#!/bin/zsh
set -eu

repo_root="$(cd "${0:A:h}/.." && pwd -P)"
source "$repo_root/dotfiles/.zsh/gtr-helpers.zsh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/gtr-prune.XXXXXX")"
test_root="${test_root:A}"
trap 'rm -rf -- "$test_root"' EXIT
repository="$test_root/repository"
worktree_path="$test_root/repository-stale"
healthy_path="$test_root/repository-healthy"
failed_path="$test_root/repository-unpruned"
prune_should_fail=0

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command git init -q "$repository"
command git -C "$repository" config user.email test@example.com
command git -C "$repository" config user.name Test
command git -C "$repository" config commit.gpgsign false
command git -C "$repository" commit --allow-empty -qm initial
command git -C "$repository" worktree add -qb stale "$worktree_path"
command git -C "$repository" worktree add -qb healthy "$healthy_path"
rm -rf -- "$worktree_path"

command git -C "$repository" worktree list --porcelain | grep -Fqx "worktree $worktree_path" || \
    fail "test setup did not retain the missing worktree registration"
command git -C "$repository" worktree list --porcelain | grep -Fq "prunable gitdir file points to non-existent location" || \
    fail "test setup did not produce the expected prunable registration"

git() {
    if [[ "$*" == "fetch --prune" ]]; then
        return 0
    fi
    if [[ "$*" == "gtr list --porcelain" ]]; then
        printf '%s\t%s\t%s\n' "$repository" main ok
        command git worktree list --porcelain | grep -Fqx "worktree $worktree_path" && \
            printf '%s\t%s\t%s\n' "$worktree_path" stale missing
        command git worktree list --porcelain | grep -Fqx "worktree $failed_path" && \
            printf '%s\t%s\t%s\n' "$failed_path" unpruned missing
        printf '%s\t%s\t%s\n' "$healthy_path" healthy ok
        return 0
    fi
    if [[ "$*" == "for-each-ref --format=%(upstream:short) refs/heads/healthy" ]]; then
        return 0
    fi
    if [[ "$*" == "worktree prune --expire now" && $prune_should_fail -eq 1 ]]; then
        return 1
    fi
    command git "$@"
}

cd "$repository"
gtr-prune --dry-run > "$test_root/dry-run-output.log"
command git worktree list --porcelain | grep -Fqx "worktree $worktree_path" || \
    fail "dry-run removed the stale worktree registration"

gtr-prune > "$test_root/output.log"
command git worktree list --porcelain | grep -Fqx "worktree $worktree_path" && \
    fail "gtr-prune left the stale worktree registered"
[[ -d "$healthy_path" ]] || fail "gtr-prune removed a healthy worktree directory"
command git worktree list --porcelain | grep -Fqx "worktree $healthy_path" || \
    fail "gtr-prune removed a healthy worktree registration"
grep -Fqx "Removed 1 worktree(s)" "$test_root/output.log" || \
    fail "gtr-prune did not report exactly one verified removal"

command git worktree add -qb unpruned "$failed_path"
rm -rf -- "$failed_path"
prune_should_fail=1
gtr-prune > "$test_root/failed-output.log" 2>&1
command git worktree list --porcelain | grep -Fqx "worktree $failed_path" || \
    fail "failed-prune test did not retain the registration"
grep -Fqx "Removed 0 worktree(s)" "$test_root/failed-output.log" || \
    fail "gtr-prune reported a removal whose metadata remained registered"

echo "PASS: gtr-prune immediately removes and verifies stale Git registrations"
echo "PASS: gtr-prune preserves healthy registered worktrees"
echo "PASS: gtr-prune dry-run does not remove the worktree"
echo "PASS: gtr-prune only reports removal after Git metadata is gone"
