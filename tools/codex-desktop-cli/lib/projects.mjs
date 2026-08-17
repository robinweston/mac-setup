import { spawn } from 'node:child_process';
import { mkdir, readFile, realpath, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const DEFAULT_APP = '/Applications/ChatGPT.app';

export function globalStatePath(env = process.env) {
  return path.join(env.CODEX_HOME || path.join(os.homedir(), '.codex'), '.codex-global-state.json');
}

function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`Invalid ${label} in Codex global state`);
  return value;
}

export function parseProjectState(value) {
  const state = object(value, 'root object');
  const rawProjects = object(state['local-projects'] ?? {}, 'local-projects');
  const order = Array.isArray(state['project-order']) ? state['project-order'] : [];
  const assignments = object(state['thread-project-assignments'] ?? {}, 'thread-project-assignments');
  const projectsById = new Map();

  for (const [key, raw] of Object.entries(rawProjects)) {
    object(raw, `project ${key}`);
    if (typeof raw.id !== 'string' || raw.id !== key) throw new Error(`Invalid project id for ${key}`);
    if (typeof raw.name !== 'string' || !raw.name) throw new Error(`Invalid project name for ${key}`);
    if (!Array.isArray(raw.rootPaths) || raw.rootPaths.length === 0
      || raw.rootPaths.some((root) => typeof root !== 'string' || !path.isAbsolute(root))) {
      throw new Error(`Invalid rootPaths for project ${key}`);
    }
    projectsById.set(key, { id: raw.id, name: raw.name, rootPaths: [...raw.rootPaths] });
  }

  const orderedIds = [...new Set([...order, ...projectsById.keys()])];
  const projects = orderedIds.map((id) => projectsById.get(id)).filter(Boolean);
  return { projects, assignments };
}

export async function readProjectState({ statePath = globalStatePath() } = {}) {
  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      return parseProjectState(JSON.parse(await readFile(statePath, 'utf8')));
    } catch (error) {
      lastError = error;
      if (!(error instanceof SyntaxError) || attempt === 2) throw error;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }
  throw lastError;
}

async function canonicalExistingDirectory(input, { create = false } = {}) {
  const resolved = path.resolve(input);
  if (create) await mkdir(resolved, { recursive: true });
  let info;
  try {
    info = await stat(resolved);
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error(`Project directory does not exist: ${resolved} (pass --create to create it)`);
    throw error;
  }
  if (!info.isDirectory()) throw new Error(`Project path is not a directory: ${resolved}`);
  return realpath(resolved);
}

function samePath(left, right) {
  return path.resolve(left) === path.resolve(right);
}

export function findProjects(projects, idOrPath) {
  const byId = projects.filter((project) => project.id === idOrPath);
  if (byId.length > 0) return byId;
  const candidate = path.resolve(idOrPath);
  return projects.filter((project) => project.rootPaths.some((root) => samePath(root, candidate)));
}

export function findProject(projects, idOrPath) {
  return findProjects(projects, idOrPath)[0] ?? null;
}

export function projectForCwd(projects, cwd) {
  if (typeof cwd !== 'string' || !path.isAbsolute(cwd)) return null;
  return projects
    .flatMap((project) => project.rootPaths.map((root) => ({ project, root: path.resolve(root) })))
    .filter(({ root }) => {
      const relative = path.relative(root, path.resolve(cwd));
      return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
    })
    .sort((a, b) => b.root.length - a.root.length)[0]?.project ?? null;
}

function runOpen(appPath, projectPath) {
  return new Promise((resolve, reject) => {
    const child = spawn('/usr/bin/open', ['-a', appPath, projectPath], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', reject);
    child.once('exit', (code) => code === 0 ? resolve() : reject(new Error(`open exited ${code}: ${stderr.trim()}`)));
  });
}

export async function addProject(input, {
  create = false,
  timeoutMs = 15_000,
  pollMs = 250,
  appPath = process.env.CODEX_DESKTOP_APP || DEFAULT_APP,
  statePath = globalStatePath(),
  openProject = runOpen,
} = {}) {
  const projectPath = await canonicalExistingDirectory(input, { create });
  const before = await readProjectState({ statePath });
  const existing = findProject(before.projects, projectPath);
  if (existing) return { project: existing, registered: false };

  await openProject(appPath, projectPath);
  const deadline = Date.now() + timeoutMs;
  do {
    const current = await readProjectState({ statePath });
    const project = findProject(current.projects, projectPath);
    if (project) return { project, registered: true };
    await new Promise((resolve) => setTimeout(resolve, pollMs));
  } while (Date.now() < deadline);
  throw new Error(`ChatGPT.app did not register ${projectPath} within ${timeoutMs}ms`);
}

export async function resolveProject(idOrPath, options = {}) {
  const state = await readProjectState(options);
  const existing = findProject(state.projects, idOrPath);
  if (existing) return { project: existing, registered: false };
  if (!path.isAbsolute(path.resolve(idOrPath)) || /^[0-9a-f-]{20,}$/i.test(idOrPath)) {
    throw new Error(`Unknown project id: ${idOrPath}`);
  }
  return addProject(idOrPath, options);
}
