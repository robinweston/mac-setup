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
fake_codex="$test_root/fake bin/codex-desktop-cli"
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
}

gtr-prune() {
    print -r -- "gtr-prune-called"
}
EOF

mkdir -p "${fake_codex:h}"
cat > "$fake_codex" <<'EOF'
#!/bin/zsh
print -r -- "codex-cwd=$PWD"
print -rl -- "$@"
EOF
chmod +x "$fake_codex"

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
[[ "$output" == *'threads'*$'\n''new'* ]] || fail "Codex Desktop CLI thread creation was not requested"
[[ "$output" == *'--project'*$'\n'"$worktree"* ]] || fail "Codex Desktop CLI received the wrong project"
[[ "$output" == *'--prompt'*$'\n''$review-pr Review the pull request at https://bitbucket.org/cetarktech/api/pull-requests/42'* ]] || fail "review-pr skill prompt was not supplied"
[[ "$output" == *'--reasoning-effort'*$'\n''high'* ]] || fail "high reasoning effort was not supplied"
[[ "$output" == *'--sandbox'*$'\n''workspace-write'* ]] || fail "workspace-write sandbox was not supplied"
[[ "$output" == *'--approval-policy'*$'\n''never'* ]] || fail "non-interactive approval policy was not supplied"
[[ "$output" == *'--network-access'* ]] || fail "network access was not supplied"
git_common_directory="$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir)"
git_directory="$(git -C "$worktree" rev-parse --path-format=absolute --git-dir)"
[[ "$output" == *'--add-dir'*$'\n'"$git_common_directory"* ]] || fail "shared Git metadata access was not supplied"
[[ "$output" == *'--add-dir'*$'\n'"$git_directory"* ]] || fail "worktree-specific Git metadata access was not supplied"
[[ "$output" == *'--add-dir'*$'\n'"$fake_home/.config/bkt"* ]] || fail "bkt credential-lock access was not supplied"
[[ "$output" == *'--add-dir'*$'\n'"$fake_home/Library/Application Support/bkt"* ]] || fail "bkt macOS state access was not supplied"
add_dir_count=0
for output_line in "${(@f)output}"; do
    [[ "$output_line" == '--add-dir' ]] && (( add_dir_count += 1 ))
done
(( add_dir_count == 4 )) || fail "Codex received $add_dir_count writable roots instead of the four required roots"

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
print -- "PASS: gtr-new-to-Codex review handoff"
print -- "PASS: linked-worktree and bkt writable roots preserve spaces"
print -- "PASS: merged PR worktree pruning"
