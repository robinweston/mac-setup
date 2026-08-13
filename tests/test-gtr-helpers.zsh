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

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "expected output to contain '$2', got '$1'"
}

assert_equal "$(_gtr_parse_bitbucket_url 'https://bitbucket.org/cetarktech/genai-products/pull-requests/256#comment-838617473')" $'pull-request\tcetarktech\tgenai-products\t256'
assert_equal "$(_gtr_parse_bitbucket_url 'https://bitbucket.org/cetarktech/genai-products/branch/gen-668-mutation-testing?tab=commits')" $'branch\tcetarktech\tgenai-products\tgen-668-mutation-testing'
if _gtr_parse_bitbucket_url 'https://example.com/pull-requests/256' >/dev/null; then
    fail "non-Bitbucket URL was detected as a Bitbucket URL"
fi

default_home="$test_root/home"
default_repository="$default_home/git/products/genai-products"
custom_root="$test_root/custom-repositories"
custom_repository="$custom_root/services/api"
outside_repository="$test_root/outside"
mkdir -p "$default_repository" "$custom_repository" "$outside_repository"

for repository in "$default_repository" "$custom_repository"; do
    git init -q "$repository"
    touch "$repository/README.md"
    git -C "$repository" add README.md
    git -C "$repository" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false commit -qm initial
done
git -C "$default_repository" remote add origin work_git:cetarktech/genai-products.git
git -C "$custom_repository" remote add origin https://bitbucket.org/cetarktech/api.git
git -C "$default_repository" update-ref refs/remotes/origin/feature/from-pr HEAD
git -C "$custom_repository" update-ref refs/remotes/origin/gen-668-mutation-testing HEAD

bkt() {
    [[ "${(j: :)@}" == "$EXPECTED_BKT_ARGS" ]] || fail "unexpected bkt arguments: $*"
    printf '%s\n' '{"pull_request":{"source":{"branch":{"name":"feature/from-pr"}}}}'
}

gtr() {
    if [[ "$1" == new && "$2" == --cd ]]; then
        CREATED_BRANCH="$3"
    fi
    printf 'gtr:%s|cwd=%s\n' "${(j: :)@}" "$PWD"
}

git() {
    if [[ "$1 $2" == 'gtr editor' ]]; then
        printf 'editor:%s|cwd=%s\n' "$3" "$PWD"
    elif [[ "$1 $2" == 'rev-parse --show-toplevel' ]]; then
        if [[ "$PWD" == "$default_repository" || "$PWD" == "$default_repository"/* ]]; then
            printf '%s\n' "$default_repository"
        elif [[ "$PWD" == "$custom_repository" || "$PWD" == "$custom_repository"/* ]]; then
            printf '%s\n' "$custom_repository"
        else
            return 1
        fi
    elif [[ "$1 $2" == 'rev-parse --abbrev-ref' && -n "${CREATED_BRANCH:-}" ]]; then
        printf '%s\n' "$CREATED_BRANCH"
    else
        command git "$@"
    fi
}

_gtr_fetch_origin_for_branch_check() {
    return 0
}

EXPECTED_BKT_ARGS='pr view 256 --workspace cetarktech --repo genai-products --json'
result="$(cd "$outside_repository" && HOME="$default_home" gtr-new 'https://bitbucket.org/cetarktech/genai-products/pull-requests/256')"
assert_contains "$result" "gtr:new --cd feature/from-pr --track remote --no-fetch|cwd=$default_repository"
assert_contains "$result" "editor:feature/from-pr|cwd=$default_repository"

result="$(cd "$outside_repository" && GTR_REPOSITORY_ROOT="$custom_root" gtr-new 'https://bitbucket.org/cetarktech/api/branch/gen-668-mutation-testing' --from-current)"
assert_contains "$result" "gtr:new --cd gen-668-mutation-testing --from-current --track remote --no-fetch|cwd=$custom_repository"
assert_contains "$result" "editor:gen-668-mutation-testing|cwd=$custom_repository"

gtr() {
    return 1
}
failure_directory="$(cd "$outside_repository" && GTR_REPOSITORY_ROOT="$custom_root" gtr-new 'https://bitbucket.org/cetarktech/api/branch/gen-668-mutation-testing' >/dev/null 2>&1 || true; pwd -P)"
assert_equal "$failure_directory" "$outside_repository"

assert_equal "$(_gtr_jira_issue_key_from_url 'https://example.atlassian.net/browse/ABC-123')" "ABC-123"
assert_equal "$(_gtr_jira_issue_key_from_url 'https://jira.example.com/browse/team_2-9?focusedCommentId=1')" "TEAM_2-9"
if _gtr_jira_issue_key_from_url 'feature/my-branch' >/dev/null; then
    fail "ordinary branch name was detected as a Jira URL"
fi

acli() {
    printf '%s\n' '{"fields":{"summary":"Fix checkout: don'\''t lose saved cards!"}}'
}

gtr() {
    if [[ "$1" == new && "$2" == --cd ]]; then
        CREATED_BRANCH="$3"
    fi
    printf 'gtr:%s|cwd=%s\n' "${(j: :)@}" "$PWD"
}

jira_outside_error="$(cd "$outside_repository" && gtr-new 'https://example.atlassian.net/browse/ABC-123' 2>&1)" && \
    fail "Jira URL was accepted outside a Git worktree"
assert_equal "$jira_outside_error" 'a Jira URL requires running gtr-new inside a Git worktree'

result="$(cd "$default_repository" && gtr-new 'https://example.atlassian.net/browse/ABC-123' --from main)"
assert_contains "$result" 'Using branch name: abc-123-fix-checkout-don-t-lose-saved-cards'
assert_contains "$result" 'gtr:new --cd abc-123-fix-checkout-don-t-lose-saved-cards --from main --track none --no-fetch'
assert_contains "$result" 'editor:abc-123-fix-checkout-don-t-lose-saved-cards'

result="$(cd "$default_repository" && gtr-new 'plain-branch' --from-current)"
assert_contains "$result" 'gtr:new --cd plain-branch --from-current --track none --no-fetch'
assert_contains "$result" 'editor:plain-branch'

unfunction acli
missing_acli_output="$(cd "$default_repository" && PATH=/nonexistent gtr-new 'https://example.atlassian.net/browse/ABC-404' 2>&1)" && \
    fail "missing acli still created a branch"
assert_equal "$missing_acli_output" $'Cannot create a branch for Jira issue ABC-404: Atlassian CLI (acli) is not installed.\nInstall it with:\n  brew tap atlassian/homebrew-acli\n  brew install acli'

acli() {
    echo 'not authenticated' >&2
    return 1
}

if (cd "$default_repository" && gtr-new 'https://example.atlassian.net/browse/ABC-999' 2>/dev/null); then
    fail "Jira lookup failure still created a branch"
fi

echo "PASS: unified Bitbucket URL parsing"
echo "PASS: PR URL repository and branch resolution"
echo "PASS: branch URL repository and branch resolution"
echo "PASS: remote worktree option forwarding"
echo "PASS: remote failure directory restoration"
echo "PASS: Jira worktree requirement"
echo "PASS: Jira summary branch slugging"
echo "PASS: Jira option forwarding"
echo "PASS: plain branch compatibility"
echo "PASS: missing acli guidance"
echo "PASS: Jira lookup failure handling"
