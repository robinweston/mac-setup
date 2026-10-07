#!/usr/bin/env python3
"""Open a feature chat in its repository project through Codex app-server."""
import json
import os
from pathlib import Path
import queue
import sqlite3
import subprocess
import tempfile
import threading
import uuid


class CodexAPI:
    def __enter__(self):
        self.errors = tempfile.TemporaryFile(mode='w+t')
        self.process = subprocess.Popen(['codex', 'app-server'], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.errors, text=True)
        self.messages = queue.Queue()
        def read():
            for line in self.process.stdout:
                try:
                    self.messages.put(json.loads(line))
                except ValueError:
                    continue
            self.messages.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.sequence = 0
        try:
            self.call('initialize', {'clientInfo': {'name': 'mac_setup_coding_agent',
                        'title': 'Mac setup coding agent', 'version': '1'},
                        'capabilities': {'experimentalApi': True, 'requestAttestation': False}})
            self.send({'method': 'initialized'})
        except Exception:
            self.__exit__(None, None, None)
            raise
        return self

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + '\n')
        self.process.stdin.flush()

    def call(self, method, params):
        self.sequence += 1
        number = self.sequence
        self.send({'id': number, 'method': method, 'params': params})
        while True:
            try:
                message = self.messages.get(timeout=30)
            except queue.Empty:
                raise RuntimeError(f'Codex app-server timed out: {method}')
            if message is None:
                raise RuntimeError(f'Codex app-server exited during {method}')
            if message.get('id') != number:
                if 'id' in message and 'method' in message:
                    self.send({'id': message['id'], 'error': {'code': -32601,
                               'message': 'This launcher does not process server requests'}})
                continue
            if 'error' in message:
                raise RuntimeError(f"Codex {method}: {message['error']}")
            return message['result']

    def list(self, method, params=None):
        items, cursor = [], None
        while True:
            result = self.call(method, dict(params or {}, limit=100, cursor=cursor))
            items.extend(result['data'])
            cursor = result.get('nextCursor')
            if not cursor:
                return items

    def __exit__(self, *_):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdin.close()
        self.reader.join(timeout=5)
        self.process.stdout.close()
        self.errors.close()


def ensure_project(api, repository, name):
    repository = str(Path(repository).resolve())
    matches = [p for p in api.list('project/list')
               if any(str(Path(r['path']).resolve()) == repository for r in p['roots'])]
    if len(matches) > 1:
        raise RuntimeError(f'Multiple Codex projects contain {repository}; consolidate them first')
    if matches:
        return matches[0]
    return api.call('project/create', {'name': name, 'roots': [{'path': repository}],
                    'idempotencyKey': str(uuid.uuid5(uuid.NAMESPACE_URL, 'mac-setup:' + repository))})['project']


def draft_threads(api, paths):
    # thread/list omits chats that have no user message yet. Read their IDs
    # without changing the database; all thread mutations still use the API.
    codex_dir = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
    databases = [p for p in codex_dir.glob('state_*.sqlite')
                 if p.stem.removeprefix('state_').isdigit()]
    if not databases:
        return []
    database = max(databases, key=lambda p: int(p.stem.removeprefix('state_')))
    placeholders = ','.join('?' for _ in paths)
    try:
        con = sqlite3.connect(f'{database.resolve().as_uri()}?mode=ro', uri=True)
    except sqlite3.Error as error:
        raise RuntimeError(f'Cannot read unopened Codex chats: {error}') from error
    try:
        ids = con.execute(
            f"SELECT id FROM threads WHERE cwd IN ({placeholders}) "
            "AND archived=0 AND has_user_event=0 "
            "AND source IN ('cli','vscode','appServer') ORDER BY updated_at_ms DESC",
            paths).fetchall()
    except sqlite3.Error as error:
        raise RuntimeError(f'Cannot read unopened Codex chats: {error}') from error
    finally:
        con.close()
    return [api.call('thread/read', {'threadId': tid, 'includeTurns': False})['thread']
            for (tid,) in ids]


def feature_thread(api, project, worktree, feature, previous_path=None):
    paths = [str(Path(worktree).resolve())]
    if previous_path is not None:
        previous_path = str(Path(previous_path).resolve())
        if previous_path not in paths:
            paths.append(previous_path)
    threads = api.list('thread/list', {'cwd': paths, 'modelProviders': [], 'sourceKinds': ['cli', 'vscode', 'appServer'],
                      'sortKey': 'updated_at', 'sortDirection': 'desc', 'useStateDbOnly': True})
    if not threads:
        threads = draft_threads(api, paths)
    # Reuse the latest interactive chat and preserve its history.
    threads = [t for t in threads if not t.get('parentThreadId')]
    if threads:
        thread = threads[0]
        api.call('thread/metadata/update', {'threadId': thread['id'], 'projectId': project['id']})
        if thread['cwd'] != paths[0]:
            api.call('thread/resume', {'threadId': thread['id'], 'excludeTurns': True})
            api.call('thread/settings/update', {'threadId': thread['id'], 'cwd': paths[0]})
    else:
        thread = api.call('thread/start', {'cwd': paths[0], 'projectId': project['id'],
                          'ephemeral': False})['thread']
        api.call('thread/inject_items', {'threadId': thread['id'], 'items': [{
            'type': 'message', 'role': 'user',
            'content': [{'type': 'input_text', 'text':
                f'Workspace prepared for {feature}. Wait for my next instruction before starting work.'}]
        }]})
    api.call('thread/name/set', {'threadId': thread['id'], 'name': feature})
    return thread['id']


def open_feature(repository, worktree, project_name, feature, previous_path=None):
    with CodexAPI() as api:
        project = ensure_project(api, repository, project_name)
        thread_id = feature_thread(api, project, worktree, feature, previous_path)
    subprocess.run(['open', 'codex://threads/' + thread_id], check=True)
    return thread_id
