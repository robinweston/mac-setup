#!/bin/zsh
set -eu

repo_root="$(cd "${0:A:h}/.." && pwd -P)"
source "$repo_root/dotfiles/.zsh/gtr-helpers.zsh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/gtr-prune.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
git_log="$test_root/git.log"
worktree_path="$test_root/repository-feature"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

git() {
    case "$*" in
        "fetch --prune") return 0 ;;
        "gtr list --porcelain")
            printf '%s\t%s\t%s\n' "$test_root/repository" main ok
            printf '%s\t%s\t%s\n' "$worktree_path" feature ok
            ;;
        "for-each-ref --format=%(upstream:short) refs/heads/feature")
            print -r -- origin/feature
            ;;
        "rev-parse --verify --quiet refs/remotes/origin/feature^{commit}") return 1 ;;
        "gtr rm feature --delete-branch --force --yes")
            print -r -- "$*" >> "$git_log"
            ;;
        *) fail "unexpected git call: $*" ;;
    esac
}

gtr-prune > "$test_root/output.log"
[[ "$(<"$git_log")" == "gtr rm feature --delete-branch --force --yes" ]] || \
    fail "gtr-prune did not remove the expected worktree"

: > "$git_log"
gtr-prune --dry-run > "$test_root/dry-run-output.log"
[[ ! -s "$git_log" ]] || fail "dry-run removed a worktree"

echo "PASS: gtr-prune removes worktrees without Codex CLI integration"
echo "PASS: gtr-prune dry-run does not remove the worktree"
