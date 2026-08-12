#!/bin/zsh
set -eu

repo_root="$(cd "${0:A:h}/.." && pwd -P)"
source "$repo_root/dotfiles/.zsh/gtr-helpers.zsh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_equal "$(_gtr_jira_issue_key_from_url 'https://example.atlassian.net/browse/ABC-123')" "ABC-123"
assert_equal "$(_gtr_jira_issue_key_from_url 'https://jira.example.com/browse/team_2-9?focusedCommentId=1')" "TEAM_2-9"
if _gtr_jira_issue_key_from_url 'feature/my-branch' >/dev/null; then
    fail "ordinary branch name was detected as a Jira URL"
fi

acli() {
    printf '%s\n' "{\"fields\":{\"summary\":\"Fix checkout: don't lose saved cards!\"}}"
}

git() {
    case "$1 $2" in
        'show-ref --verify') return 1 ;;
        'rev-parse --abbrev-ref') printf '%s\n' 'abc-123-fix-checkout-don-t-lose-saved-cards' ;;
        'gtr editor') EDITOR_BRANCH="$3" ;;
        *) fail "unexpected git command: $*" ;;
    esac
}

gtr() {
    GTR_ARGS=("$@")
}

_gtr_fetch_origin_for_branch_check() {
    return 0
}

gtrnew 'https://example.atlassian.net/browse/ABC-123' --from main
assert_equal "${(j: :)GTR_ARGS}" 'new --cd abc-123-fix-checkout-don-t-lose-saved-cards --from main --track none --no-fetch'
assert_equal "$EDITOR_BRANCH" 'abc-123-fix-checkout-don-t-lose-saved-cards'

gtrnew 'plain-branch' --from-current
assert_equal "${(j: :)GTR_ARGS}" 'new --cd plain-branch --from-current --track none --no-fetch'

unfunction acli
missing_acli_output="$(PATH=/nonexistent gtrnew 'https://example.atlassian.net/browse/ABC-404' 2>&1)" && \
    fail "missing acli still created a branch"
assert_equal "$missing_acli_output" $'Cannot create a branch for Jira issue ABC-404: Atlassian CLI (acli) is not installed.\nInstall it with:\n  brew tap atlassian/homebrew-acli\n  brew install acli'

acli() {
    echo 'not authenticated' >&2
    return 1
}

if gtrnew 'https://example.atlassian.net/browse/ABC-999' 2>/dev/null; then
    fail "Jira lookup failure still created a branch"
fi

echo "PASS: Jira URL parsing"
echo "PASS: Jira summary branch slugging"
echo "PASS: gtrnew option forwarding"
echo "PASS: ordinary branch compatibility"
echo "PASS: missing acli guidance"
echo "PASS: Jira lookup failure handling"
