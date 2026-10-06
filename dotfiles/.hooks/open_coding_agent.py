#!/usr/bin/env python3
"""Open a Bitbucket pull request in a persistent Git worktree and Codex."""

import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()


def repository_identity(remote):
    match = re.search(r"[/:]([^/:]+)/([^/]+?)(?:\.git)?$", remote.rstrip("/"))
    return f"{match.group(1)}/{match.group(2)}" if match else None


def find_repository(root, identity):
    matches = []
    for directory, children, _ in os.walk(root):
        candidate = Path(directory)
        if len(candidate.relative_to(root).parts) > 4 or (candidate / ".git").is_file():
            children.clear()
            continue
        if ".git" not in children:
            continue
        children.clear()
        try:
            if repository_identity(run("git", "config", "--get", "remote.origin.url", cwd=candidate)) == identity:
                matches.append(candidate)
        except subprocess.CalledProcessError:
            pass
    if len(matches) != 1:
        raise RuntimeError(f"expected one base checkout for {identity} under {root}; found {len(matches)}")
    return matches[0]


def worktrees(repository):
    current = None
    for line in run("git", "worktree", "list", "--porcelain", cwd=repository).splitlines():
        if line.startswith("worktree "):
            if current is not None:
                yield current
            current = {"path": Path(line[9:]).resolve()}
        elif current is not None and line.startswith("branch refs/heads/"):
            current["branch"] = line[len("branch refs/heads/"):]
        elif current is not None and line.startswith("locked"):
            current["locked"] = True
    if current is not None:
        yield current


def ref_exists(repository, ref):
    return subprocess.run(
        ("git", "show-ref", "--verify", "--quiet", ref), cwd=repository,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def source_clone_url(origin, source_identity, ssh_url, https_url):
    if source_identity == repository_identity(origin):
        return "origin"
    preferred = "ssh" if origin.startswith(("git@", "ssh://", "work_git:")) else "https"
    if preferred == "ssh":
        if ssh_url:
            return ssh_url
        return f"git@bitbucket.org:{source_identity}.git"
    if https_url:
        return https_url
    return f"https://bitbucket.org/{source_identity}.git"


def is_temporary(path):
    return any(path.is_relative_to(root.resolve()) for root in
               (Path('/tmp'), Path('/var/tmp'), Path(tempfile.gettempdir())))


def main():
    url = os.environ.get("PR_MONITOR_PR_URL", "")
    parsed = urlparse(url)
    match = re.fullmatch(r"/([^/]+)/([^/]+)/pull-requests/(\d+)/?", parsed.path)
    if parsed.scheme != "https" or parsed.hostname != "bitbucket.org" or not match:
        raise RuntimeError("PR_MONITOR_PR_URL must be a Bitbucket Cloud pull request URL")
    workspace, slug, number = (unquote(part) for part in match.groups())
    if any(part in ('.', '..') or '/' in part or '\\' in part for part in (workspace, slug)):
        raise RuntimeError("PR URL contains an invalid repository path")
    identity = f"{workspace}/{slug}"
    root = Path(os.environ.get("PR_MONITOR_REPOSITORY_ROOT", str(Path.home() / "git"))).resolve()
    repository = find_repository(root, identity)

    # Rapid clicks must not fetch into the same ref or create the same worktree
    # concurrently. Keep the lock file: unlinking it can split waiting callers
    # across different inodes.
    git_directory = Path(run("git", "rev-parse", "--git-common-dir", cwd=repository))
    if not git_directory.is_absolute():
        git_directory = repository / git_directory
    with (git_directory / "pr-monitor-open.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        open_repository(repository, identity, number, root)


def open_repository(repository, identity, number, root):
    branch = os.environ.get("PR_MONITOR_SOURCE_BRANCH", "").removeprefix("refs/heads/")
    if not branch:
        raise RuntimeError("PR_MONITOR_SOURCE_BRANCH must be set from the PR metadata supplied by PR Monitor")
    event = json.loads(os.environ.get("PR_MONITOR_EVENT_JSON", "{}"))
    title = event.get("pullRequestTitle", "")
    folder = re.sub(r"[^A-Za-z0-9._-]+", "-", title).strip(".-").lower()[:200]
    if not folder:
        folder = f"pr-{number}"
    source_identity = os.environ.get("PR_MONITOR_SOURCE_REPOSITORY", identity)
    origin = run("git", "config", "--get", "remote.origin.url", cwd=repository)
    remote = source_clone_url(
        origin,
        source_identity,
        os.environ.get("PR_MONITOR_SOURCE_SSH_CLONE_URL"),
        os.environ.get("PR_MONITOR_SOURCE_HTTPS_CLONE_URL"),
    )
    remote_ref = f"refs/remotes/pr-monitor/{number}"
    run("git", "fetch", remote, f"+refs/heads/{branch}:{remote_ref}", cwd=repository)

    local_branch = branch if source_identity == identity else f"pr/{number}/{branch}"
    if source_identity != identity:
        folder = f"pr-{number}-{folder}"
    managed_directory = root / "worktrees" / identity
    destination = managed_directory / folder
    for item in worktrees(repository):
        if item.get("branch") == local_branch and not item["path"].is_dir():
            if item.get("locked"):
                raise RuntimeError(f"worktree is missing but locked; restore or unlock it: {item['path']}")
            # Git otherwise keeps deleted worktrees registered for its grace
            # period and reports the branch as already checked out there.
            run("git", "worktree", "prune", "--expire", "now", cwd=repository)
            break
    for item in worktrees(repository):
        if item.get("branch") == local_branch:
            worktree = item["path"]
            if (worktree != repository and worktree != destination
                    and (is_temporary(worktree) or worktree.is_relative_to(managed_directory))):
                if destination.exists():
                    raise RuntimeError(f"worktree destination already exists: {destination}")
                destination.parent.mkdir(parents=True, exist_ok=True)
                # Git updates its registration and preserves all local files.
                # Do not force a move of a locked worktree.
                run("git", "worktree", "move", str(worktree), str(destination), cwd=repository)
                worktree = destination
            break
    else:
        worktree = destination
        if worktree.exists():
            raise RuntimeError(f"worktree destination already exists: {worktree}")
        worktree.parent.mkdir(parents=True, exist_ok=True)
        if ref_exists(repository, f"refs/heads/{local_branch}"):
            run("git", "worktree", "add", str(worktree), local_branch, cwd=repository)
        else:
            run("git", "worktree", "add", "-b", local_branch, str(worktree), remote_ref, cwd=repository)

    if not run("git", "status", "--porcelain", cwd=worktree):
        ancestor = subprocess.run(
            ("git", "merge-base", "--is-ancestor", "HEAD", remote_ref), cwd=worktree,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode == 0
        if ancestor:
            run("git", "merge", "--ff-only", remote_ref, cwd=worktree)
        else:
            print(f"Warning: {local_branch} has diverged from the PR head; leaving it unchanged", file=sys.stderr)
    else:
        print(f"Warning: {worktree} has local changes; leaving it unchanged", file=sys.stderr)

    print(f"Opening {worktree} ({local_branch}) in Codex")
    run("codex", "app", str(worktree))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, KeyError, ValueError, OSError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        print(f"open coding agent: {detail}", file=sys.stderr)
        sys.exit(1)
