import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { DEFAULT_APPROVAL_POLICY } from '../lib/app-server.mjs';
import { addProject, findProject, parseProjectState, projectForCwd } from '../lib/projects.mjs';

function state(projects = {}, order = [], assignments = {}) {
  return {
    'local-projects': projects,
    'project-order': order,
    'thread-project-assignments': assignments,
  };
}

test('defaults new threads to interactive approval', () => {
  assert.equal(DEFAULT_APPROVAL_POLICY, 'unlessTrusted');
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
