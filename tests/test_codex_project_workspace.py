#!/usr/bin/env python3
"""Integration checks against Codex app-server in an isolated local data directory."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dotfiles/.hooks'))
from codex_project_workspace import CodexAPI, ensure_project, feature_thread


class CodexProjectWorkspaceTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        codex_dir = self.root / 'codex'
        codex_dir.mkdir()
        environment = patch.dict(os.environ, {'CODEX_HOME': str(codex_dir)})
        environment.start()
        self.addCleanup(environment.stop)
        self.repository = self.root / 'repository'
        self.worktree = self.root / 'feature'
        self.repository.mkdir()
        self.worktree.mkdir()

    def create_feature(self):
        with CodexAPI() as api:
            project = ensure_project(api, self.repository, 'parent-repository')
            thread_id = feature_thread(api, project, self.worktree, 'Feature title')
        return project, thread_id

    def test_reuse_empty_chat_after_server_restart_and_worktree_move(self):
        project, original = self.create_feature()
        with CodexAPI() as api:
            parent = ensure_project(api, self.repository, 'parent-repository')
            self.assertEqual(parent['id'], project['id'])
            self.assertEqual(feature_thread(api, parent, self.worktree, 'Feature title'), original)
        renamed = self.root / 'renamed-feature'
        self.worktree.rename(renamed)
        with CodexAPI() as api:
            thread_id = feature_thread(api, project, renamed, 'Renamed feature', self.worktree)
            self.assertEqual(thread_id, original)
        with CodexAPI() as api:
            thread = api.call('thread/read', {'threadId': original, 'includeTurns': False})['thread']
            self.assertEqual(thread['cwd'], str(renamed.resolve()))
            self.assertEqual(thread['projectId'], project['id'])
            self.assertEqual(thread['name'], 'Renamed feature')

    def test_archived_empty_chat_is_not_reopened(self):
        project, archived = self.create_feature()
        with CodexAPI() as api:
            api.call('thread/archive', {'threadId': archived})
        with CodexAPI() as api:
            new = feature_thread(api, project, self.worktree, 'Feature title')
        self.assertNotEqual(new, archived)


if __name__ == '__main__':
    unittest.main()
