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

fake_home="$test_root/home directory"
mkdir -p "$fake_home/.local/bin" "$fake_home/.zsh"

{
    print '#!/bin/zsh'
    print -r -- 'print -r -- "gtr-new-args=$*"'
} > "$fake_home/.local/bin/gtr-new"
chmod +x "$fake_home/.local/bin/gtr-new"

cat > "$fake_home/.zsh/gtr-helpers.zsh" <<'EOF'
gtr-prune() {
    print -r -- "gtr-prune-called"
}
EOF

coding_agent_output="$(
    PR_MONITOR_EVENT=open_coding_agent \
    PR_MONITOR_REPOSITORY=api \
    PR_MONITOR_PR_ID=42 \
    PR_MONITOR_PR_URL=https://bitbucket.org/cetarktech/api/pull-requests/42 \
    HOME="$fake_home" \
    "$hooks/run"
)"

[[ "$coding_agent_output" == \
    'gtr-new-args=https://bitbucket.org/cetarktech/api/pull-requests/42 --open' ]] ||
    fail "coding agent hook did not invoke the installed gtr-new executable"

for merged_event in my_pr_merged reviewed_pr_merged; do
    merged_output="$(
        PR_MONITOR_EVENT="$merged_event" \
        HOME="$fake_home" \
        "$hooks/run"
    )"

    [[ "$merged_output" == "gtr-prune-called" ]] ||
        fail "$merged_event did not run gtr-prune"
done

noop_output="$(PR_MONITOR_EVENT=build_failed_on_my_pr "$hooks/run")"
[[ "$noop_output" == 'No dotfiles hook configured for build_failed_on_my_pr' ]] ||
    fail "unconfigured event was not ignored"

if PR_MONITOR_EVENT='../review_assigned_to_me' "$hooks/run" >/dev/null 2>&1; then
    fail "unsafe event name was accepted"
fi

print -- "PASS: event-name dispatch"
print -- "PASS: unconfigured event no-op"
print -- "PASS: open coding agent handoff through installed gtr-new"
print -- "PASS: merged PR worktree pruning"
