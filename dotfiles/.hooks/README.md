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

`open_coding_agent` runs the companion `open_coding_agent.py` script. It uses Git worktrees under a sibling `<repository>-worktrees` directory and opens the checkout with `codex app`. The script requires `bkt`, Git, Python 3, and Codex CLI. Set `PR_MONITOR_REPOSITORY_ROOT` if base checkouts are outside `~/git`.
