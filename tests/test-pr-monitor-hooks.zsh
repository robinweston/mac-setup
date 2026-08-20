#!/bin/zsh

set -eu

repo_root="$(cd "${0:A:h}/.." && pwd -P)"
hooks="$repo_root/dotfiles/.hooks"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/pr-monitor-hooks.XXXXXX")"
test_root="${test_root:A}"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    print -u2 -- "FAIL: $*"
    exit 1
}

base_repository="$test_root/base repository"
worktree="$test_root/review worktree"
fake_home="$test_root/home directory"
shell_init="$fake_home/.zsh/gtr-helpers.zsh"
gtr_cache="$test_root/cache/gtr/init-gtr.zsh"

git init -q "$base_repository"
git -C "$base_repository" remote add origin work_git:cetarktech/api.git
touch "$base_repository/README.md"
git -C "$base_repository" add README.md
git -C "$base_repository" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false commit -qm initial
git -C "$base_repository" branch feature/review
git -C "$base_repository" worktree add -q "$worktree" feature/review

mkdir -p "${shell_init:h}"
cat > "$fake_home/.zshrc" <<'EOF'
print -u2 -- ".zshrc must not be sourced by the PR Monitor hook"
return 1
EOF

cat > "$shell_init" <<'EOF'
gtr-new() {
    [[ "$1" == "$TEST_PR_URL" ]] || {
        print -u2 -- "gtr-new received the wrong URL: $1"
        return 1
    }
    cd -- "$TEST_PR_WORKTREE"
    print -r -- "gtr-new-url=$1"
    print -r -- "gtr-new-cwd=$PWD"
}

gtr-prune() {
    print -r -- "gtr-prune-called"
}
EOF

mkdir -p "${gtr_cache:h}"
cat > "$gtr_cache" <<'EOF'
gtr() {
    return 0
}
compdef _gtr_completion gtr
EOF

HOME="$fake_home" \
XDG_CACHE_HOME="${gtr_cache:h:h}" \
REPO_GTR_HELPERS="$repo_root/dotfiles/.zsh/gtr-helpers.zsh" \
/bin/zsh -c '
    source "$REPO_GTR_HELPERS"
    (( $+functions[gtr] )) && exit 1
    _gtr_ensure_shell_integration
    (( $+functions[gtr] ))
    (( ! $+functions[compdef] ))
' || fail "gtr shell integration was not loaded for a non-interactive caller"

cached_helper_output="$(
    HOME="$fake_home" \
    XDG_CACHE_HOME="${gtr_cache:h:h}" \
    REPO_GTR_HELPERS="$repo_root/dotfiles/.zsh/gtr-helpers.zsh" \
    TEST_PR_WORKTREE="$worktree" \
    TEST_PR_URL=https://bitbucket.org/cetarktech/api/pull-requests/42 \
    /bin/zsh -c '
        source "$REPO_GTR_HELPERS"
        open() { print -r -- "open-cwd=$PWD" }
        cd -- "$TEST_PR_WORKTREE"
        _gtr_remember_target_worktree "$TEST_PR_URL"
        cd -- /
        _gtr_find_base_repository() {
            print -u2 -- "expensive repository lookup must not run"
            return 99
        }
        gtr-new "$TEST_PR_URL"
    '
)"
[[ "$cached_helper_output" == *"Using cached worktree for https://bitbucket.org/cetarktech/api/pull-requests/42"* ]] || fail "gtr-new did not find its cached target"
[[ "$cached_helper_output" == *"open-cwd=$worktree"* ]] || fail "gtr-new opened the wrong cached worktree"
[[ "$cached_helper_output" != *"expensive repository lookup must not run"* ]] || fail "gtr-new performed repository lookup for a cached target"

coding_agent_output="$(
    PR_MONITOR_EVENT=open_coding_agent \
    PR_MONITOR_REPOSITORY=api \
    PR_MONITOR_PR_ID=42 \
    PR_MONITOR_PR_URL=https://bitbucket.org/cetarktech/api/pull-requests/42 \
    TEST_PR_WORKTREE="$worktree" \
    TEST_PR_URL=https://bitbucket.org/cetarktech/api/pull-requests/42 \
    HOME="$fake_home" \
    "$hooks/run"
)"

[[ "$coding_agent_output" == *'gtr-new-url=https://bitbucket.org/cetarktech/api/pull-requests/42'* ]] || fail "coding agent hook passed the wrong PR URL"
[[ "$coding_agent_output" == *"gtr-new-cwd=$worktree"* ]] || fail "coding agent hook did not open the PR worktree"

for merged_event in my_pr_merged reviewed_pr_merged; do
    merged_output="$(
        PR_MONITOR_EVENT="$merged_event" \
        HOME="$fake_home" \
        "$hooks/run"
    )"

    [[ "$merged_output" == "gtr-prune-called" ]] || \
        fail "$merged_event did not run gtr-prune"
done

noop_output="$(PR_MONITOR_EVENT=build_failed_on_my_pr "$hooks/run")"
[[ "$noop_output" == 'No dotfiles hook configured for build_failed_on_my_pr' ]] || fail "unconfigured event was not ignored"

if PR_MONITOR_EVENT='../review_assigned_to_me' "$hooks/run" >/dev/null 2>&1; then
    fail "unsafe event name was accepted"
fi

print -- "PASS: event-name dispatch"
print -- "PASS: unconfigured event no-op"
print -- "PASS: non-interactive gtr shell integration"
print -- "PASS: gtr target worktree cache"
print -- "PASS: open coding agent handoff through optimized gtr-new"
print -- "PASS: merged PR worktree pruning"
