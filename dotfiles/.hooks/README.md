# PR Monitor hooks

`run` dispatches a PR Monitor event to an executable in this directory with the same name as `PR_MONITOR_EVENT`. Configure PR Monitor with one wildcard hook:

```json
{
  "event": "*",
  "command": "\"$HOME/.hooks/run\"",
  "enabled": true
}
```

Events without a matching executable are ignored. Hook scripts receive the original stdin and all `PR_MONITOR_*` environment variables.

`my_pr_merged` and `reviewed_pr_merged` run the installed
`cleanup-worktrees` skill pruner. It removes only stale Git registrations whose
worktree directories are already missing; the scheduled cleanup handles branches.

`open_coding_agent` runs the companion `open_coding_agent.py` script. It creates Git worktrees under `~/git/worktrees/<workspace>/<repository>/<pr-title-folder>` and opens a feature chat under the base repository’s Codex project. The companion `codex_project_workspace.py` uses the Codex app-server API to find or create the parent project, assign the feature chat, and open its `codex://threads/<id>` link. The parent project keeps the base checkout as its root; the chat works in the feature worktree. This prevents each feature directory from becoming a separate sidebar project. The folder uses `pullRequestTitle` from `PR_MONITOR_EVENT_JSON`, converting it to lowercase, replacing spaces and unsafe characters with hyphens, and limiting the title to 200 characters. Missing or unusable titles fall back to `pr-<number>`. Fork PR folders also have a `pr-<number>-` prefix. PR Monitor passes `PR_MONITOR_SOURCE_BRANCH` from its PR data when invoking the hook. For a fork PR, it also passes `PR_MONITOR_SOURCE_REPOSITORY` and the available `PR_MONITOR_SOURCE_SSH_CLONE_URL` and `PR_MONITOR_SOURCE_HTTPS_CLONE_URL`. The script requires Git, Python 3, and Codex CLI. Set `PR_MONITOR_REPOSITORY_ROOT` if base checkouts are outside `~/git`; worktrees then live in that root's `worktrees` directory.

Repeated clicks reuse the source branch's worktree. If its directory was deleted,
the hook prunes stale Git registrations and recreates the checkout, preserving the
local branch. Locked missing worktrees require restoring or unlocking first.
Overlapping clicks are serialized per repository to avoid Git ref and worktree
creation races. Existing local changes and diverged branches are left intact.
Existing worktrees in temporary directories or this hook's repository worktree directory are moved to the current PR-title directory
on the next open using `git worktree move`, preserving tracked and untracked local
files, including after a PR title changes. Other persistent checkouts are reused at their current paths. Moves do
not overwrite occupied destinations or force locked worktrees.

The chat name uses the PR title. Repeated clicks reuse the most recently updated interactive chat for that worktree and update its name. Archived chats and subagents are not selected. A moved worktree is matched by its previous path so it reuses the same chat. Existing conversations remain stored; the launcher records feature context without starting a model turn or beginning agent work. Codex omits chats without user turns from its list API, so the helper uses a read-only lookup of those chat IDs in Codex’s local state database; all project and chat changes go through the app-server API. Codex CLI must support the experimental project and thread app-server methods. If those methods fail, the hook reports the error instead of opening the feature as a separate project.
