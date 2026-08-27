#!/usr/bin/env zsh

set -euo pipefail

repo_root="${0:A:h:h}"
GTR_NEW_SOURCE_ONLY=1
source "$repo_root/tools/gtr-new"
unset GTR_NEW_SOURCE_ONLY

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

_gtr_new_branch_from_jira_issue() {
    print -r -- "$expected_branch"
}

_gtr_new_fetch_origin_for_branch_check() {
    return 0
}

_gtr_new_open_chatgpt() {
    print -r -- "$1" > "$test_root/opened"
}

cd -- "$repository"
output="$(gtr_new_main 'https://arktech-au.atlassian.net/browse/GEN-685' --porcelain --open)"

[[ "$output" == *$'path\t'"$worktree"* ]] || fail "porcelain output did not contain the existing worktree"
[[ "$output" == *$'branch\t'"$expected_branch"* ]] || fail "porcelain output did not contain the Jira branch"
[[ "$output" == *$'hook_status\texisting'* ]] || fail "existing worktree status was not reported"
[[ "$(< "$test_root/opened")" == "$worktree" ]] || fail "ChatGPT was not opened at the existing worktree"

target='https://bitbucket.org/cetarktech/api/pull-requests/42'
XDG_CACHE_HOME="$test_root/cache"
export XDG_CACHE_HOME
_gtr_new_remember_target_worktree "$target" "$worktree"
_gtr_new_find_base_repository() {
    fail "cached target performed repository lookup"
}

cached_output="$(gtr_new_main "$target" --porcelain --no-open)"
[[ "$cached_output" == *$'path\t'"$worktree"* ]] || fail "cached target returned the wrong worktree"
[[ "$cached_output" == *$'hook_status\tcached'* ]] || fail "cached target status was not reported"

fake_home="$test_root/home"
mkdir -p "$fake_home/.local/bin"
cp "$repo_root/tools/gtr-new" "$fake_home/.local/bin/gtr-new"
chmod +x "$fake_home/.local/bin/gtr-new"

# Replace the installed executable with a deterministic stand-in to verify the
# interactive wrapper changes its parent shell after requesting an open.
mv "$fake_home/.local/bin/gtr-new" "$fake_home/.local/bin/gtr-new-real"
{
    print '#!/bin/zsh'
    print -r -- 'print -r -- "$*" > "$TEST_GTR_ARGS"'
    print -r -- 'printf "path\\t%s\\nbranch\\tfeature/test\\nhook_status\\texisting\\n" "$TEST_GTR_WORKTREE"'
} > "$fake_home/.local/bin/gtr-new"
chmod +x "$fake_home/.local/bin/gtr-new"

HOME="$fake_home"
TEST_GTR_ARGS="$test_root/interactive-args"
TEST_GTR_WORKTREE="$worktree"
export HOME TEST_GTR_ARGS TEST_GTR_WORKTREE
source "$repo_root/dotfiles/.zsh/gtr-interactive.zsh"
cd -- "$repository"
gtr-new feature/test >/dev/null

[[ "$PWD" == "$worktree" ]] || fail "interactive gtr-new did not change directory"
[[ "$(< "$TEST_GTR_ARGS")" == 'feature/test --porcelain' ]] || fail "interactive wrapper passed unexpected arguments"

fake_bin="$test_root/fake-bin"
package_directory="$test_root/package"
mkdir -p "$fake_bin" "$package_directory"
touch "$package_directory/package.json"
{
    print '#!/bin/sh'
    print "printf ':\\n'"
} > "$fake_bin/fnm"
{
    print '#!/bin/sh'
    print -r -- 'printf "%s\n" "$*" > "$TEST_NPM_ARGS"'
} > "$fake_bin/npm"
chmod +x "$fake_bin/fnm" "$fake_bin/npm"

TEST_NPM_ARGS="$test_root/npm-args"
export TEST_NPM_ARGS
(
    cd -- "$package_directory"
    PATH="$fake_bin:$PATH" /bin/sh "$repo_root/tools/gtr-post-create"
)
[[ "$(< "$TEST_NPM_ARGS")" == install ]] || fail "post-create hook did not run npm install"

print -- "PASS: executable gtr-new reuses Jira worktrees and opens ChatGPT"
print -- "PASS: executable gtr-new reuses cached URL targets"
print -- "PASS: interactive gtr-new changes the current terminal directory"
print -- "PASS: relocated post-create hook runs npm install"
