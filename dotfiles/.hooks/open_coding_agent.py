#!/usr/bin/env python3
"""Open a Bitbucket pull request in a sibling Git worktree and Codex."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
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
    if current is not None:
        yield current


def ref_exists(repository, ref):
    return subprocess.run(
        ("git", "show-ref", "--verify", "--quiet", ref), cwd=repository,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def source_repository(pr):
    repository = pr.get("source", {}).get("repository") or {}
    if repository.get("full_name"):
        return repository["full_name"]
    workspace = repository.get("workspace") or {}
    workspace = workspace.get("slug") if isinstance(workspace, dict) else workspace
    return f"{workspace}/{repository['slug']}" if workspace and repository.get("slug") else None


def source_clone_url(pr, origin, source_identity):
    if source_identity == repository_identity(origin):
        return "origin"
    links = (pr.get("source", {}).get("repository") or {}).get("links") or {}
    clones = links.get("clone") or []
    preferred = "ssh" if origin.startswith(("git@", "ssh://", "work_git:")) else "https"
    for clone in clones:
        if clone.get("name") == preferred and clone.get("href"):
            return clone["href"]
    if preferred == "ssh":
        return f"git@bitbucket.org:{source_identity}.git"
    return f"https://bitbucket.org/{source_identity}.git"


def main():
    url = os.environ.get("PR_MONITOR_PR_URL", "")
    parsed = urlparse(url)
    match = re.fullmatch(r"/([^/]+)/([^/]+)/pull-requests/(\d+)/?", parsed.path)
    if parsed.scheme != "https" or parsed.hostname != "bitbucket.org" or not match:
        raise RuntimeError("PR_MONITOR_PR_URL must be a Bitbucket Cloud pull request URL")
    workspace, slug, number = (unquote(part) for part in match.groups())
    identity = f"{workspace}/{slug}"
    root = Path(os.environ.get("PR_MONITOR_REPOSITORY_ROOT", str(Path.home() / "git"))).resolve()
    repository = find_repository(root, identity)

    payload = json.loads(run("bkt", "pr", "view", number, "--workspace", workspace, "--repo", slug, "--json"))
    pr = payload.get("pull_request", payload)
    source = pr.get("source") or {}
    branch = (source.get("branch") or {}).get("name") or source.get("branchName") or (pr.get("fromRef") or {}).get("displayId")
    if not branch:
        raise RuntimeError(f"PR #{number} has no source branch in bkt output")
    branch = branch.removeprefix("refs/heads/")
    source_identity = source_repository(pr) or identity
    origin = run("git", "config", "--get", "remote.origin.url", cwd=repository)
    remote = source_clone_url(pr, origin, source_identity)
    remote_ref = f"refs/remotes/pr-monitor/{number}"
    run("git", "fetch", remote, f"+refs/heads/{branch}:{remote_ref}", cwd=repository)

    local_branch = branch if source_identity == identity else f"pr/{number}/{branch}"
    for item in worktrees(repository):
        if item.get("branch") == local_branch:
            worktree = item["path"]
            break
    else:
        folder = re.sub(r"[^A-Za-z0-9._-]+", "-", branch).strip(".-")
        if not folder:
            raise RuntimeError("PR source branch cannot be used as a worktree folder")
        if source_identity != identity:
            folder = f"pr-{number}-{folder}"
        worktree = repository.parent / f"{repository.name}-worktrees" / folder
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
    except (RuntimeError, subprocess.CalledProcessError, KeyError, ValueError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        print(f"open coding agent: {detail}", file=sys.stderr)
        sys.exit(1)
