#!/usr/bin/env zsh

set -euo pipefail

repo_root="${0:A:h:h}"
source "$repo_root/dotfiles/.zsh/gtr-helpers.zsh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/gtr-new.XXXXXX")"
test_root="${test_root:A}"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    print -u2 -- "FAIL: $1"
    exit 1
}

repository="$test_root/repository"
worktree="$test_root/existing-worktree"
expected_branch="gen-685-investigate-revenue-discrepancy"
mkdir -p -- "$repository"
git -C "$repository" init -q
git -C "$repository" config user.email test@example.com
git -C "$repository" config user.name Test
touch "$repository/initial"
git -C "$repository" add initial
git -C "$repository" -c commit.gpgsign=false commit -qm initial
git -C "$repository" branch "$expected_branch"
git -C "$repository" worktree add -q "$worktree" "$expected_branch"

_gtr_branch_from_jira_issue() {
    print -r -- "$expected_branch"
}

_gtr_fetch_origin_for_branch_check() {
    return 0
}

gtr() {
    [[ "$1" == cd && "$2" == "$expected_branch" ]] || fail "unexpected gtr invocation: $*"
    cd -- "$worktree"
}

open() {
    [[ "$*" == "-a /Applications/ChatGPT.app ." ]] || fail "unexpected open invocation: $*"
    print -r -- "$PWD" > "$test_root/opened"
}

cd -- "$repository"
gtr-new 'https://arktech-au.atlassian.net/browse/GEN-685' > "$test_root/output"
output="$(< "$test_root/output")"

[[ "$output" == *"Using branch name: $expected_branch"* ]] || fail "Jira branch name was not reported"
[[ "$output" == *"Using existing worktree for $expected_branch"* ]] || fail "existing worktree was not reused"
[[ "$PWD" == "$worktree" ]] || fail "shell did not move to the existing worktree"
[[ "$(< "$test_root/opened")" == "$worktree" ]] || fail "ChatGPT was not opened in the existing worktree"

print -- "PASS: rerunning gtr-new for a Jira issue reuses its existing worktree"
