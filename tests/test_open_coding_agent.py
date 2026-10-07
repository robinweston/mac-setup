#!/usr/bin/env python3
"""End-to-end local Git checks for the PR Monitor Codex opener."""

import os
import json
import shutil
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'dotfiles/.hooks/open_coding_agent.py'


def run(*args, cwd=None, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f'{args}: {result.stderr}')
    return result.stdout.strip()


class OpenCodingAgentTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name).resolve()
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

        (root / 'bin/codex').write_text('#!/bin/sh\nexec python3 "' + str(Path(__file__).with_name('fake_codex.py')) + '"\n')
        (root / 'bin/open').write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\np=Path(os.environ["OPENED_LOG"])\ns=json.loads(Path(str(p)+".json").read_text())\nt=next(t for t in s["threads"] if sys.argv[1].endswith(t["id"]))\nwith p.open("a") as f: f.write(t["cwd"]+"\\n")\n')
        for tool in (root / 'bin').iterdir():
            tool.chmod(0o755)
        env = dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                   PR_MONITOR_PR_URL='https://bitbucket.org/example/sample/pull-requests/42',
                   PR_MONITOR_SOURCE_BRANCH='feature/test',
                   PR_MONITOR_EVENT_JSON=json.dumps({'pullRequestTitle': 'Improve coding agent hooks'}),
                   PR_MONITOR_REPOSITORY_ROOT=str(root / 'repos'), OPENED_LOG=str(root / 'opened'))
        worktree = root / 'repos/worktrees/example/sample/improve-coding-agent-hooks'
        self.root, self.remote, self.repository = root, remote, repository
        self.env, self.worktree = env, worktree

    def test_create_reuse_and_fast_forward(self):
        root, remote, env, worktree = self.root, self.remote, self.env, self.worktree
        for _ in range(2):
            run('python3', str(SCRIPT), env=env)
        state = json.loads((root / 'opened.json').read_text())
        self.assertEqual(len(state['projects']), 1)
        self.assertEqual(state['projects'][0]['roots'], [{'path': str(self.repository)}])
        self.assertEqual(state['projects'][0]['name'], 'sample')
        self.assertEqual(len(state['threads']), 1)
        self.assertEqual(state['threads'][0]['name'], 'Improve coding agent hooks')
        self.assertEqual(state['threads'][0]['projectId'], state['projects'][0]['id'])
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

    def test_recreate_deleted_worktree_and_reopen(self):
        # Match the real failure: a deleted /tmp checkout is still registered.
        deleted = self.root / 'temporary-checkout'
        run('git', 'worktree', 'add', str(deleted), 'feature/test', cwd=self.repository)
        shutil.rmtree(deleted)
        self.assertIn(str(deleted), run('git', 'worktree', 'list', '--porcelain', cwd=self.repository))
        for _ in range(2):
            run('python3', str(SCRIPT), env=self.env)
        self.assertTrue(self.worktree.is_dir())
        self.assertNotIn(str(deleted), run('git', 'worktree', 'list', '--porcelain', cwd=self.repository))
        self.assertEqual((self.root / 'opened').read_text().splitlines(), [str(self.worktree)] * 2)

    def test_title_change_moves_worktree_and_preserves_local_files(self):
        run('python3', str(SCRIPT), env=self.env)
        (self.worktree / 'readme').write_text('local edits\n')
        (self.worktree / 'untracked').write_text('keep me\n')
        env = dict(self.env, PR_MONITOR_EVENT_JSON=json.dumps({'pullRequestTitle': '../Fix: hooks / safely!'}))
        run('python3', str(SCRIPT), env=env)
        renamed = self.worktree.parent / 'fix-hooks-safely'
        state = json.loads((self.root / 'opened.json').read_text())
        self.assertEqual(len(state['threads']), 1)
        self.assertEqual(state['threads'][0]['name'], '../Fix: hooks / safely!')
        self.assertEqual(state['threads'][0]['cwd'], str(renamed))
        self.assertFalse(self.worktree.exists())
        self.assertEqual((renamed / 'readme').read_text(), 'local edits\n')
        self.assertEqual((renamed / 'untracked').read_text(), 'keep me\n')
        self.assertEqual((self.root / 'opened').read_text().splitlines(), [str(self.worktree), str(renamed)])

    def test_missing_or_unusable_title_uses_pr_number(self):
        for title in ('', '../ !!!'):
            with self.subTest(title=title):
                env = dict(self.env, PR_MONITOR_EVENT_JSON=json.dumps({'pullRequestTitle': title}))
                run('python3', str(SCRIPT), env=env)
        self.assertEqual((self.root / 'opened').read_text().splitlines(),
                         [str(self.worktree.parent / 'pr-42')] * 2)

    def test_move_temporary_worktree_preserves_local_files(self):
        old = self.root / 'temporary-checkout'
        run('git', 'worktree', 'add', str(old), 'feature/test', cwd=self.repository)
        (old / 'readme').write_text('local edits\n')
        (old / 'untracked').write_text('keep me\n')
        for _ in range(2):
            run('python3', str(SCRIPT), env=self.env)
        self.assertFalse(old.exists())
        self.assertEqual((self.worktree / 'readme').read_text(), 'local edits\n')
        self.assertEqual((self.worktree / 'untracked').read_text(), 'keep me\n')
        self.assertEqual(run('git', 'branch', '--show-current', cwd=self.worktree), 'feature/test')
        self.assertEqual((self.root / 'opened').read_text().splitlines(), [str(self.worktree)] * 2)

    def test_move_does_not_overwrite_destination(self):
        old = self.root / 'temporary-checkout'
        run('git', 'worktree', 'add', str(old), 'feature/test', cwd=self.repository)
        self.worktree.mkdir(parents=True)
        (self.worktree / 'keep').write_text('keep me\n')
        result = subprocess.run(('python3', str(SCRIPT)), env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('destination already exists', result.stderr)
        self.assertTrue(old.is_dir())
        self.assertEqual((self.worktree / 'keep').read_text(), 'keep me\n')

    def test_locked_missing_worktree_is_preserved(self):
        run('git', 'worktree', 'add', str(self.worktree), 'feature/test', cwd=self.repository)
        run('git', 'worktree', 'lock', str(self.worktree), cwd=self.repository)
        shutil.rmtree(self.worktree)
        result = subprocess.run(('python3', str(SCRIPT)), env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('missing but locked', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertIn('locked', run('git', 'worktree', 'list', '--porcelain', cwd=self.repository))
        self.assertFalse((self.root / 'opened').exists())

    def test_two_features_share_repository_project(self):
        run('python3', str(SCRIPT), env=self.env)
        run('git', 'branch', 'feature/second', 'feature/test', cwd=self.repository)
        run('git', 'push', 'origin', 'feature/second', cwd=self.repository)
        env = dict(self.env, PR_MONITOR_SOURCE_BRANCH='feature/second',
                   PR_MONITOR_EVENT_JSON=json.dumps({'pullRequestTitle': 'Second feature'}))
        run('python3', str(SCRIPT), env=env)
        state = json.loads((self.root / 'opened.json').read_text())
        self.assertEqual(len(state['projects']), 1)
        self.assertEqual(len(state['threads']), 2)
        self.assertEqual({t['projectId'] for t in state['threads']}, {state['projects'][0]['id']})
        self.assertEqual({t['name'] for t in state['threads']},
                         {'Improve coding agent hooks', 'Second feature'})

    def test_overlapping_clicks(self):
        # Hold the first fetch until all callers have started, so their Git
        # operations overlap without the opener's repository lock.
        git = shutil.which('git')
        wrapper = self.root / 'bin/git'
        wrapper.write_text('#!/bin/sh\nif [ "$1" = fetch ]; then\n'
                           '  touch "$FETCH_STARTED"\n'
                           '  while [ ! -f "$FETCH_RELEASE" ]; do sleep 0.01; done\n'
                           'fi\nexec "$REAL_GIT" "$@"\n')
        wrapper.chmod(0o755)
        env = dict(self.env, REAL_GIT=git, FETCH_STARTED=str(self.root / 'fetch-started'),
                   FETCH_RELEASE=str(self.root / 'fetch-release'))
        callers = [subprocess.Popen(('python3', str(SCRIPT)), env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(4)]
        try:
            deadline = time.monotonic() + 10
            while not (self.root / 'fetch-started').exists():
                if time.monotonic() > deadline:
                    self.fail('first click never reached fetch')
                time.sleep(0.01)
            (self.root / 'fetch-release').touch()
            for caller in callers:
                stdout, stderr = caller.communicate(timeout=20)
                self.assertEqual(caller.returncode, 0, stdout + stderr)
        finally:
            for caller in callers:
                if caller.poll() is None:
                    caller.kill()
                caller.communicate()
        self.assertEqual((self.root / 'opened').read_text().splitlines(), [str(self.worktree)] * 4)


if __name__ == '__main__':
    unittest.main()
