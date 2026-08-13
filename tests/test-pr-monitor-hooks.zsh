#!/bin/zsh

set -eu

repo_root="$(cd "${0:A:h}/.." && pwd -P)"
hooks="$repo_root/dotfiles/.config/pr-monitor/hooks"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/pr-monitor-hooks.XXXXXX")"
test_root="${test_root:A}"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    print -u2 -- "FAIL: $*"
    exit 1
}

base_repository="$test_root/base"
worktree="$test_root/worktree"
fake_home="$test_root/home"
shell_init="$fake_home/.zsh/gtr-helpers.zsh"
fake_codex="$test_root/codex"

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
gtrpr() {
    [[ "$1" == "$TEST_PR_URL" ]] || {
        print -u2 -- "gtrpr received the wrong URL: $1"
        return 1
    }
    cd -- "$TEST_PR_WORKTREE"
}
EOF

cat > "$fake_codex" <<'EOF'
#!/bin/zsh
print -r -- "codex-cwd=$PWD"
print -rl -- "$@"
EOF
chmod +x "$fake_codex"

output="$(
    PR_MONITOR_EVENT=review_assigned_to_me \
    PR_MONITOR_REPOSITORY=api \
    PR_MONITOR_PR_ID=42 \
    PR_MONITOR_PR_URL=https://bitbucket.org/cetarktech/api/pull-requests/42 \
    PR_REVIEW_CODEX_BIN="$fake_codex" \
    TEST_PR_WORKTREE="$worktree" \
    TEST_PR_URL=https://bitbucket.org/cetarktech/api/pull-requests/42 \
    HOME="$fake_home" \
    "$hooks/run"
)"

[[ "$output" == *"Starting Codex review in $worktree"* ]] || fail "Codex did not start in the PR worktree"
[[ "$output" == *"codex-cwd=$worktree"* ]] || fail "Codex received the wrong working directory"
[[ "$output" == *'$review-pr Review the pull request at https://bitbucket.org/cetarktech/api/pull-requests/42'* ]] || fail "review-pr skill prompt was not supplied"
[[ "$output" == *'model_reasoning_effort="high"'* ]] || fail "high reasoning effort was not supplied"

noop_output="$(PR_MONITOR_EVENT=build_failed_on_my_pr "$hooks/run")"
[[ "$noop_output" == 'No dotfiles hook configured for build_failed_on_my_pr' ]] || fail "unconfigured event was not ignored"

if PR_MONITOR_EVENT='../review_assigned_to_me' "$hooks/run" >/dev/null 2>&1; then
    fail "unsafe event name was accepted"
fi

print -- "PASS: event-name dispatch"
print -- "PASS: unconfigured event no-op"
print -- "PASS: gtrpr-to-Codex review handoff"
