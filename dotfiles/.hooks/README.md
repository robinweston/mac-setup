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

`open_coding_agent` passes the pull-request URL to the installed
`~/.local/bin/gtr-new` executable. `gtr-new` first checks the worktree cached
when it previously resolved that URL, skipping Bitbucket lookup, repository
scanning, and Git fetch when the worktree already exists. A missing or stale
cache continues through the normal resolution and creation flow, then refreshes
the cache and opens ChatGPT at the worktree.
