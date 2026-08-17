import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  DEFAULT_APPROVAL_POLICY,
  validateApprovalPolicy,
  workspaceWriteSandboxPolicy,
} from '../lib/app-server.mjs';
import {
  addProject,
  findProject,
  findProjects,
  parseProjectState,
  projectForCwd,
} from '../lib/projects.mjs';
import {
  ALL_THREAD_SOURCE_KINDS,
  archiveProjectThreads,
  selectProjectThreads,
} from '../lib/threads.mjs';

function state(projects = {}, order = [], assignments = {}) {
  return {
    'local-projects': projects,
    'project-order': order,
    'thread-project-assignments': assignments,
  };
}

test('defaults new threads to interactive approval', () => {
  assert.equal(DEFAULT_APPROVAL_POLICY, 'on-request');
});

test('accepts only app-server string approval policies', () => {
  for (const policy of ['untrusted', 'on-request', 'never']) {
    assert.equal(validateApprovalPolicy(policy), policy);
  }
  assert.throws(() => validateApprovalPolicy('unlessTrusted'), /Unsupported approval policy/);
  assert.throws(() => validateApprovalPolicy('granular'), /Unsupported approval policy/);
});

test('builds workspace-write policy with network and additional roots', () => {
  assert.deepEqual(workspaceWriteSandboxPolicy({
    writableRoots: ['/tmp/repository/.git/', '/tmp/repository/.git', '/tmp/home/.config/bkt'],
    networkAccess: true,
  }), {
    type: 'workspaceWrite',
    writableRoots: ['/tmp/repository/.git', '/tmp/home/.config/bkt'],
    networkAccess: true,
  });
  assert.equal(workspaceWriteSandboxPolicy(), null);
  assert.throws(() => workspaceWriteSandboxPolicy({ writableRoots: ['relative'] }), /absolute path/);
});

test('validates and orders Desktop project state', () => {
  const parsed = parseProjectState(state({
    p1: { id: 'p1', name: 'One', rootPaths: ['/tmp/one'] },
    p2: { id: 'p2', name: 'Two', rootPaths: ['/tmp/two'] },
  }, ['p2', 'p1'], { t1: { projectKind: 'local', projectId: 'p1' } }));
  assert.deepEqual(parsed.projects.map((project) => project.id), ['p2', 'p1']);
  assert.equal(parsed.assignments.t1.projectId, 'p1');
  assert.throws(() => parseProjectState(state({ bad: { id: 'other', name: 'Bad', rootPaths: ['/tmp'] } })), /Invalid project id/);
});

test('resolves exact project roots and longest cwd containment', () => {
  const projects = [
    { id: 'parent', name: 'Parent', rootPaths: ['/tmp/work'] },
    { id: 'child', name: 'Child', rootPaths: ['/tmp/work/nested'] },
  ];
  assert.equal(findProject(projects, 'parent').id, 'parent');
  assert.equal(findProject(projects, '/tmp/work/nested').id, 'child');
  assert.equal(projectForCwd(projects, '/tmp/work/nested/src').id, 'child');
  assert.equal(projectForCwd(projects, '/tmp/work-other'), null);
});

test('finds every duplicate Desktop project for an exact root', () => {
  const projects = [
    { id: 'one', name: 'One', rootPaths: ['/tmp/work'] },
    { id: 'two', name: 'Two', rootPaths: ['/tmp/work'] },
    { id: 'other', name: 'Other', rootPaths: ['/tmp/other'] },
  ];
  assert.deepEqual(findProjects(projects, '/tmp/work').map(({ id }) => id), ['one', 'two']);
});

test('selects project threads by assignment or most-specific cwd', () => {
  const projects = [
    { id: 'parent', name: 'Parent', rootPaths: ['/tmp/work'] },
    { id: 'child', name: 'Child', rootPaths: ['/tmp/work/nested'] },
  ];
  const threads = [
    { id: 'parent-cwd', cwd: '/tmp/work/src' },
    { id: 'child-cwd', cwd: '/tmp/work/nested/src' },
    { id: 'assigned', cwd: '/tmp/other' },
    { id: 'assigned-away', cwd: '/tmp/work' },
  ];
  const selected = selectProjectThreads(threads, projects, {
    assignments: {
      assigned: { projectKind: 'local', projectId: 'parent' },
      'assigned-away': { projectKind: 'local', projectId: 'child' },
    },
  }, [projects[0]]);
  assert.deepEqual(selected.map(({ id }) => id), ['parent-cwd', 'assigned']);
  assert.ok(ALL_THREAD_SOURCE_KINDS.includes('subAgent'));
  assert.ok(ALL_THREAD_SOURCE_KINDS.includes('vscode'));
});

test('archives only root threads and lets app-server cascade to descendants', async () => {
  const projects = [{ id: 'project', name: 'Project', rootPaths: ['/tmp/work'] }];
  const archived = [];
  const client = {
    async request(method, params) {
      if (method === 'thread/list') {
        assert.equal(params.archived, false);
        assert.deepEqual(params.sourceKinds, ALL_THREAD_SOURCE_KINDS);
        return {
          data: [
            { id: 'root', cwd: '/tmp/work' },
            { id: 'child', cwd: '/tmp/work', parentThreadId: 'root' },
          ],
          nextCursor: null,
        };
      }
      if (method === 'thread/archive') {
        archived.push(params.threadId);
        return {};
      }
      throw new Error(`Unexpected request: ${method}`);
    },
  };

  const result = await archiveProjectThreads(projects, projects, {
    client,
    state: { assignments: {} },
  });

  assert.deepEqual(archived, ['root']);
  assert.equal(result.threadCount, 2);
  assert.equal(result.archiveRootCount, 1);
});

test('delegates registration and polls until Desktop state contains the project', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'codex-projects-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const projectPath = path.join(directory, 'project');
  const statePath = path.join(directory, 'state.json');
  await mkdir(projectPath);
  await writeFile(statePath, JSON.stringify(state()));

  let opened;
  const result = await addProject(projectPath, {
    statePath,
    timeoutMs: 500,
    pollMs: 5,
    openProject: async (appPath, openedPath) => {
      opened = { appPath, openedPath };
      await writeFile(statePath, JSON.stringify(state({
        p1: { id: 'p1', name: 'project', rootPaths: [openedPath] },
      }, ['p1'])));
    },
  });

  assert.equal(opened.appPath, '/Applications/ChatGPT.app');
  assert.equal(opened.openedPath, await realpath(projectPath));
  assert.equal(result.registered, true);
  assert.equal(result.project.id, 'p1');
});
