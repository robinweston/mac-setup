#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
launcher="$repo_root/dotfiles/.local/bin/ccode"
test_root="$(mktemp -d /tmp/c.XXXXXX)"
test_home="$test_root/home"
shared_home="$test_root/shared"
mock_bin="$test_root/bin"
user_data="$test_root/user-data"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_link() {
    [ -L "$1" ] || fail "$1 is not a symlink"
    [ "$(readlink "$1")" = "$2" ] || fail "$1 does not point to $2"
}

mkdir -p \
    "$test_home/.config/Code/User" \
    "$shared_home" \
    "$mock_bin" \
    "$user_data/User"
printf 'auth\n' >"$shared_home/auth.json"
printf 'config\n' >"$shared_home/config.toml"
printf 'settings\n' >"$test_home/.config/Code/User/settings.json"

printf '%s\n' \
    '#!/bin/sh' \
    'printf '\''%s\n'\'' "$CODEX_HOME" >"$CCODE_TEST_CAPTURE"' \
    >"$mock_bin/code"
chmod +x "$mock_bin/code"

launch_workspace() {
    workspace="$1"
    capture="$2"
    mkdir -p "$workspace"
    (
        cd "$workspace"
        HOME="$test_home" \
        CODEX_SHARED_HOME="$shared_home" \
        CODEX_VSCODE_USER_DATA_DIR="$user_data" \
        CCODE_TEST_CAPTURE="$capture" \
        PATH="$mock_bin:$PATH" \
            "$launcher"
    )
}

sh -n "$launcher"

workspace_one="$test_root/workspace-one"
workspace_two="$test_root/workspace-two"
launch_workspace "$workspace_one" "$test_root/one.txt"
launch_workspace "$workspace_two" "$test_root/two.txt"

codex_home_one="$(cat "$test_root/one.txt")"
codex_home_two="$(cat "$test_root/two.txt")"
shared_locks="$shared_home/mcp-oauth-locks"

# Codex can atomically replace the auth symlink with an identical regular file.
# The next launch repairs that file without requiring manual cleanup.
rm "$codex_home_one/auth.json"
cp "$shared_home/auth.json" "$codex_home_one/auth.json"
launch_workspace "$workspace_one" "$test_root/one-relaunch.txt"
assert_link "$codex_home_one/auth.json" "$shared_home/auth.json"

[ "$codex_home_one" != "$codex_home_two" ] || fail "workspaces resolved to the same CODEX_HOME"
assert_link "$codex_home_one/mcp-oauth-locks" "$shared_locks"
assert_link "$codex_home_two/mcp-oauth-locks" "$shared_locks"

# The same credential account hash resolves through both CODEX_HOMEs to the
# same file, while different hashes retain independent lock files.
account_one="$(printf '%s' 'atlassian|credential-one' | shasum -a 256 | awk '{print $1}')"
account_two="$(printf '%s' 'atlassian|credential-two' | shasum -a 256 | awk '{print $1}')"
lock_one_from_workspace_one="$codex_home_one/mcp-oauth-locks/$account_one.lock"
lock_one_from_workspace_two="$codex_home_two/mcp-oauth-locks/$account_one.lock"
lock_two="$codex_home_two/mcp-oauth-locks/$account_two.lock"
printf 'lock-one\n' >"$lock_one_from_workspace_one"
printf 'lock-two\n' >"$lock_two"

[ "$lock_one_from_workspace_one" -ef "$lock_one_from_workspace_two" ] || \
    fail "same credential account does not resolve to the same lock inode"
[ ! "$lock_one_from_workspace_one" -ef "$lock_two" ] || \
    fail "different credential accounts resolve to the same lock inode"

# Exercise the recoverable migration from a pre-change workspace-local lock
# directory. Its contents are preserved, while subsequent locks use the shared
# directory.
workspace_three="$test_root/workspace-three"
mkdir -p "$workspace_three"
canonical_three="$(cd "$workspace_three" && pwd -P)"
hash_three="$(printf '%s' "$canonical_three" | shasum -a 256 | awk '{print $1}')"
codex_home_three="$test_home/.cv/$hash_three"
mkdir -p "$codex_home_three/mcp-oauth-locks"
printf 'legacy\n' >"$codex_home_three/mcp-oauth-locks/stale.lock"
launch_workspace "$workspace_three" "$test_root/three.txt"
assert_link "$codex_home_three/mcp-oauth-locks" "$shared_locks"
[ -f "$codex_home_three/mcp-oauth-locks.workspace-backup/stale.lock" ] || \
    fail "legacy lock directory was not preserved during migration"

# Credential-independent runtime state remains workspace-local.
for local_path in workspace-path rules skills; do
    [ ! "$codex_home_one/$local_path" -ef "$codex_home_two/$local_path" ] || \
        fail "$local_path unexpectedly shared between workspaces"
done
[ ! -e "$codex_home_one/.credentials.json" ] || fail "fallback credential file unexpectedly created"
[ ! -L "$codex_home_one/.credentials.json" ] || fail "fallback credential file unexpectedly shared"

echo "PASS: shell syntax"
echo "PASS: separate workspace CODEX_HOME directories"
echo "PASS: identical workspace auth file is repaired automatically"
echo "PASS: shared host-global MCP OAuth lock directory"
echo "PASS: same-account locks resolve to one inode across workspaces"
echo "PASS: different-account locks remain independent"
echo "PASS: legacy lock directories are preserved during migration"
echo "PASS: runtime and fallback-file state remain workspace-local"
echo "ARTIFACTS: $test_root"
