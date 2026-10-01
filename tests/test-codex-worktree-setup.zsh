#!/usr/bin/env zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-worktree-setup.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/codex/worktrees" "$test_root/bin" "$test_root/repo"
git -C "$test_root/repo" init -q
git -C "$test_root/repo" config user.email test@example.com
git -C "$test_root/repo" config user.name Test
print '{}' > "$test_root/repo/package.json"
print '20' > "$test_root/repo/.nvmrc"
git -C "$test_root/repo" add package.json .nvmrc
git -C "$test_root/repo" -c commit.gpgsign=false commit -qm initial
git -C "$test_root/repo" worktree add -q "$test_root/codex/worktrees/test" HEAD

cat > "$test_root/bin/fnm" <<'STUB'
#!/bin/sh
if [ "$1" = env ]; then
    printf ':\n'
else
    printf '%s\n' "$*" > "$TEST_FNM_ARGS"
fi
STUB
cat > "$test_root/bin/npm" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$TEST_NPM_ARGS"
STUB
chmod +x "$test_root/bin/fnm" "$test_root/bin/npm"

export CODEX_HOME="$test_root/codex"
export TEST_FNM_ARGS="$test_root/fnm-args"
export TEST_NPM_ARGS="$test_root/npm-args"
export PATH="$test_root/bin:$PATH"

(cd "$test_root/repo" && /bin/sh "$repo_root/dotfiles/.codex/hooks/worktree-setup")
[[ ! -e "$TEST_NPM_ARGS" ]] || { print -u2 'Setup ran outside a Codex worktree'; exit 1; }

mkdir -p "$test_root/codex/worktrees/test/nested"
(cd "$test_root/codex/worktrees/test/nested" && /bin/sh "$repo_root/dotfiles/.codex/hooks/worktree-setup")
[[ "$(< "$TEST_FNM_ARGS")" == 'use --install-if-missing --silent-if-unchanged' ]]
[[ "$(< "$TEST_NPM_ARGS")" == install ]]
print 'PASS: global Codex hook sets up managed worktrees only'
