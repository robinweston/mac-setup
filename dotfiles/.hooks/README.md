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

`my_pr_merged` and `reviewed_pr_merged` run `gtr-prune`. This removes worktrees
whose remote branches disappeared after merge and archives their Codex tasks.

`review_assigned_to_me` loads `gtr-new` from `~/.zsh/gtr-helpers.zsh`, calls it with the event's pull-request URL, and uses `codex-desktop-cli` to create a `$review-pr` Codex Desktop thread in the resulting worktree. For Bitbucket pull-request and branch URLs, `gtr-new` searches `~/git` for the matching checkout by default; set `GTR_REPOSITORY_ROOT` to search elsewhere. Jira URLs and branch names create worktrees from the current checkout. Reviews run non-interactively with workspace-write isolation plus network access and narrowly scoped write access to the repository's shared Git metadata and `~/.config/bkt`, allowing Git synchronization and Bitbucket credential-lock access. Reviews default to `gpt-5.6-sol` with high reasoning effort. The Codex Desktop CLI executable, model, and effort can be overridden with `PR_REVIEW_CODEX_BIN`, `PR_REVIEW_CODEX_MODEL`, and `PR_REVIEW_CODEX_REASONING_EFFORT`.
