#!/bin/zsh
set -eu

repo_root="$(cd "${0:A:h}/.." && pwd -P)"
source "$repo_root/dotfiles/.zsh/gtr-helpers.zsh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/gtr-helpers.XXXXXX")"
test_root="${test_root:A}"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_equal "$(_gtr_parse_bitbucket_pr_url 'https://bitbucket.org/cetarktech/genai-products/pull-requests/256#comment-838617473')" $'cetarktech\tgenai-products\t256'
assert_equal "$(_gtr_parse_bitbucket_pr_url 'https://bitbucket.org/cetarktech/genai-products/pull-requests/42?tab=commits')" $'cetarktech\tgenai-products\t42'
if _gtr_parse_bitbucket_pr_url 'https://example.com/pull-requests/256' >/dev/null; then
    fail "non-Bitbucket URL was detected as a pull request"
fi
if _gtr_parse_bitbucket_pr_url '256' >/dev/null; then
    fail "bare PR number was accepted"
fi

default_home="$test_root/home"
default_repository="$default_home/git/products/genai-products"
custom_root="$test_root/custom-repositories"
custom_repository="$custom_root/services/api"
outside_repository="$test_root/outside"
mkdir -p "$default_repository" "$custom_repository" "$outside_repository"
git init -q "$default_repository"
git -C "$default_repository" remote add origin work_git:cetarktech/genai-products.git
git init -q "$custom_repository"
git -C "$custom_repository" remote add origin https://bitbucket.org/cetarktech/api.git

bkt() {
    [[ "${(j: :)@}" == "$EXPECTED_BKT_ARGS" ]] || fail "unexpected bkt arguments: $*"
    printf '%s\n' '{"pull_request":{"source":{"branch":{"name":"feature/from-pr"}}}}'
}

gtrbranch() {
    printf '%s|%s\n' "$PWD" "$1"
}

EXPECTED_BKT_ARGS='pr view 256 --workspace cetarktech --repo genai-products --json'
gtrpr_result="$(cd "$outside_repository" && HOME="$default_home" gtrpr 'https://bitbucket.org/cetarktech/genai-products/pull-requests/256')"
assert_equal "$gtrpr_result" "$default_repository|feature/from-pr"

EXPECTED_BKT_ARGS='pr view 42 --workspace cetarktech --repo api --json'
gtrpr_result="$(cd "$outside_repository" && GTR_REPOSITORY_ROOT="$custom_root" gtrpr 'https://bitbucket.org/cetarktech/api/pull-requests/42')"
assert_equal "$gtrpr_result" "$custom_repository|feature/from-pr"

gtrbranch() {
    return 1
}
failure_directory="$(cd "$outside_repository" && GTR_REPOSITORY_ROOT="$custom_root" gtrpr 'https://bitbucket.org/cetarktech/api/pull-requests/42' >/dev/null 2>&1 || true; pwd -P)"
assert_equal "$failure_directory" "$outside_repository"

outside_error="$(cd "$custom_repository" && gtrpr 42 2>&1)" && \
    fail "bare PR number was accepted inside a Git repository"
assert_equal "$outside_error" 'invalid Bitbucket pull-request URL: 42'

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
        'remote get-url') printf '%s\n' 'work_git:cetarktech/genai-products' ;;
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

echo "PASS: Bitbucket PR URL parsing"
echo "PASS: gtrpr full URL handling"
echo "PASS: gtrpr default repository discovery"
echo "PASS: gtrpr configurable repository discovery"
echo "PASS: gtrpr failure directory restoration"
echo "PASS: bare PR number rejection"
echo "PASS: Jira URL parsing"
echo "PASS: Jira summary branch slugging"
echo "PASS: gtrnew option forwarding"
echo "PASS: ordinary branch compatibility"
echo "PASS: missing acli guidance"
echo "PASS: Jira lookup failure handling"
