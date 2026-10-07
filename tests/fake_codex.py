#!/usr/bin/env python3
"""Local app-server fixture for worktree and hook tests."""
import json
import os
from pathlib import Path
import sys

state_path = Path(os.environ['OPENED_LOG'] + '.json')
state = (json.loads(state_path.read_text()) if state_path.exists()
         else {'projects': [], 'threads': []})
for line in sys.stdin:
    message = json.loads(line)
    if 'id' not in message:
        continue
    method, params = message['method'], message.get('params', {})
    if method == 'initialize':
        result = {}
    elif method == 'project/list':
        result = {'data': state['projects'], 'nextCursor': None}
    elif method == 'project/create':
        project = dict(params, id='parent-' + str(len(state['projects'])))
        state['projects'].append(project)
        result = {'project': project}
    elif method == 'thread/list':
        result = {'data': [t for t in state['threads'] if t['cwd'] in params['cwd']],
                  'nextCursor': None}
    elif method == 'thread/start':
        thread = dict(params, id='chat-' + str(len(state['threads'])),
                      parentThreadId=None, name=None)
        state['threads'].append(thread)
        result = {'thread': thread}
    elif method.startswith('thread/'):
        thread = next(t for t in state['threads'] if t['id'] == params['threadId'])
        thread.update({k: v for k, v in params.items() if k != 'threadId'})
        result = {}
    else:
        raise RuntimeError(method)
    state_path.write_text(json.dumps(state))
    print(json.dumps({'id': message['id'], 'result': result}), flush=True)
