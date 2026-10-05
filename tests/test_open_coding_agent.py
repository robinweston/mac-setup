#!/usr/bin/env python3
"""End-to-end local Git checks for the PR Monitor Codex opener."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'dotfiles/.hooks/open_coding_agent.py'


def run(*args, cwd=None, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f'{args}: {result.stderr}')
    return result.stdout.strip()


class OpenCodingAgentTest(unittest.TestCase):
    def test_create_reuse_and_fast_forward(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / 'bin').mkdir()
            (root / 'repos').mkdir()
            remote = root / 'remote.git'
            repository = root / 'repos/sample'
            run('git', 'init', '--bare', str(remote))
            run('git', 'clone', str(remote), str(repository))
            for key, value in (('user.name', 'Test'), ('user.email', 'test@example.com'), ('commit.gpgsign', 'false')):
                run('git', 'config', key, value, cwd=repository)
            (repository / 'readme').write_text('base\n')
            run('git', 'add', 'readme', cwd=repository)
            run('git', 'commit', '-m', 'base', cwd=repository)
            run('git', 'push', '-u', 'origin', 'HEAD', cwd=repository)
            base = run('git', 'branch', '--show-current', cwd=repository)
            run('git', 'checkout', '-b', 'feature/test', cwd=repository)
            (repository / 'readme').write_text('pr\n')
            run('git', 'commit', '-am', 'pr', cwd=repository)
            run('git', 'push', '-u', 'origin', 'feature/test', cwd=repository)
            run('git', 'checkout', base, cwd=repository)
            run('git', 'config', f'url.{remote}.insteadOf', 'work_git:example/sample.git', cwd=repository)
            run('git', 'remote', 'set-url', 'origin', 'work_git:example/sample.git', cwd=repository)

            (root / 'bin/codex').write_text('#!/bin/sh\necho "$2" >> "$OPENED_LOG"\n')
            for tool in (root / 'bin').iterdir():
                tool.chmod(0o755)
            env = dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                       PR_MONITOR_PR_URL='https://bitbucket.org/example/sample/pull-requests/42',
                       PR_MONITOR_SOURCE_BRANCH='feature/test',
                       PR_MONITOR_REPOSITORY_ROOT=str(root / 'repos'), OPENED_LOG=str(root / 'opened'))
            worktree = root / 'repos/sample-worktrees/feature-test'
            for _ in range(2):
                run('python3', str(SCRIPT), env=env)
            self.assertEqual(run('git', 'branch', '--show-current', cwd=worktree), 'feature/test')
            self.assertEqual((root / 'opened').read_text().splitlines(), [str(worktree)] * 2)

            another = root / 'upstream-work'
            run('git', 'clone', str(remote), str(another))
            run('git', 'checkout', 'feature/test', cwd=another)
            for key, value in (('user.name', 'Test'), ('user.email', 'test@example.com'), ('commit.gpgsign', 'false')):
                run('git', 'config', key, value, cwd=another)
            (another / 'readme').write_text('new pr commit\n')
            run('git', 'commit', '-am', 'updated', cwd=another)
            run('git', 'push', 'origin', 'feature/test', cwd=another)
            expected = run('git', 'rev-parse', 'HEAD', cwd=another)
            run('python3', str(SCRIPT), env=env)
            self.assertEqual(run('git', 'rev-parse', 'HEAD', cwd=worktree), expected)
            self.assertEqual((root / 'opened').read_text().splitlines(), [str(worktree)] * 3)


if __name__ == '__main__':
    unittest.main()
