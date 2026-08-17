# Codex Desktop projects and threads CLI

`codex-desktop-cli` is an npm-dependency-free macOS command-line adapter for four practical
Codex Desktop operations:

1. List saved local projects.
2. Register a local project through ChatGPT.app.
3. Create a thread in a project and immediately submit its first prompt.
4. List threads, optionally filtered by project.

It targets the installed ChatGPT.app/Codex Desktop build through the supported
Codex app-server interface.

## Commands

Requires Node.js 18 or newer and the Codex Desktop app in
`/Applications/ChatGPT.app`. Running `setup-mac.sh` installs a symlink in
Homebrew's `bin` directory, making `codex-desktop-cli` available on `PATH`.

To install or refresh only this command, run:

```sh
./tools/codex-desktop-cli/install.sh
```

```sh
# 1. List projects
codex-desktop-cli projects list

# 2. Register an existing directory as a Desktop project
codex-desktop-cli projects add /absolute/path/to/project

# Create the directory first only when explicitly requested
codex-desktop-cli projects add /absolute/path/to/project --create

# 3. Create a thread and submit its prompt immediately
codex-desktop-cli threads new \
  --project /absolute/path/to/project \
  --prompt "Run the test suite"

# Grant extra writable roots and network access to the workspace-write sandbox
codex-desktop-cli threads new \
  --project /absolute/path/to/project \
  --prompt "Review the pull request" \
  --add-dir /absolute/path/to/shared/git-metadata \
  --network-access

# A saved project ID works too
codex-desktop-cli threads new \
  --project 50ae409f-e574-47c3-bbd5-d50bb0fa988f \
  --prompt "Run the test suite"

# 4. List threads
codex-desktop-cli threads list --limit 20
codex-desktop-cli threads list --project /absolute/path/to/project
```

All output is JSON. `CODEX_HOME`, `CODEX_BIN`, and `CODEX_DESKTOP_APP` can
override the default state directory, Codex executable, and application path.
New threads default to the app-server `on-request` approval policy, which lets
Codex request approval when needed. The `--approval-policy` flag accepts
`untrusted`, `on-request`, or `never`; pass `never` only when non-interactive
execution is intentional. The app-server's structured granular policy is not
representable by this string-valued flag.
Repeat `--add-dir` to grant additional writable roots. `--network-access` and
`--add-dir` require the `workspace-write` sandbox.

## How it works

### Projects

`projects list` reads `~/.codex/.codex-global-state.json` and validates only the
`local-projects`, `project-order`, and `thread-project-assignments` fields. It
does not write the file.

`projects add` validates that the target is a directory, invokes:

```sh
open -a /Applications/ChatGPT.app /absolute/project/path
```

It then polls the read-only state until ChatGPT.app has registered the exact
canonical path and returns the app-created project ID. Missing directories are
rejected unless `--create` is explicitly supplied.

### Threads

`threads list` starts the Desktop-bundled `codex app-server` and calls the
supported `thread/list` method. Results are enriched using explicit
`thread-project-assignments` when present. Otherwise, the most specific saved
project containing the thread cwd is reported with `projectMatch: "cwd"`.

`threads new` resolves the supplied ID or path, registering an unsaved path
through ChatGPT.app when necessary. It calls app-server `thread/start` with the
project root as `cwd`, immediately calls `turn/start` with the prompt, and waits
for completion. It then verifies the thread appears in `thread/list` and reports
whether grouping came from an explicit assignment or cwd matching.

This build exposes no safe command-line interface for explicitly writing a
Desktop thread-to-project assignment. The tool therefore never edits global
state while the app is running. Cwd matching is reported honestly rather than
presented as an explicit Desktop assignment.

## Safety

- No Codex database, transcript, session, rollout, or global-state file is
  edited by this tool.
- Project directory creation occurs only with explicit `--create`.
- Project registration may focus/open ChatGPT.app as a normal macOS side effect.
- Thread creation submits the prompt immediately and may perform work according
  to the selected sandbox and approval policy.

## Tests

```sh
npm test
```

The focused tests cover state validation, project ordering, exact/contained
project matching, and app-owned registration polling.
