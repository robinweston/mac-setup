# PR Monitor hooks

`run` dispatches a PR Monitor event to an executable in this directory with the same name as `PR_MONITOR_EVENT`. Configure PR Monitor with one wildcard hook:

```json
{
  "event": "*",
  "command": "\"$HOME/.config/pr-monitor/hooks/run\"",
  "enabled": true
}
```

Events without a matching executable are ignored. Hook scripts receive the original stdin and all `PR_MONITOR_*` environment variables.

`review_assigned_to_me` loads `gtrpr` from `~/.zsh/gtr-helpers.zsh`, calls it with the event's pull-request URL, and starts a Phase 1 `$review-pr` Codex run in the resulting worktree. `gtrpr` requires a full Bitbucket pull-request URL. It searches `~/git` for the matching checkout by default; set `GTR_REPOSITORY_ROOT` to search elsewhere. Reviews default to `gpt-5.6-sol` with high reasoning effort. The Codex executable, model, and effort can be overridden with `PR_REVIEW_CODEX_BIN`, `PR_REVIEW_CODEX_MODEL`, and `PR_REVIEW_CODEX_REASONING_EFFORT`.
