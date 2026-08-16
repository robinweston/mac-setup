import path from 'node:path';
import { AppServerClient, runNewThread } from './app-server.mjs';
import { findProject, projectForCwd, readProjectState, resolveProject } from './projects.mjs';

async function withServer(options, callback) {
  const client = new AppServerClient(options);
  try {
    await client.connect();
    return await callback(client);
  } finally {
    await client.close();
  }
}

export async function listAppThreads({ limit = 20, archived = false, project: projectInput, ...options } = {}) {
  const state = await readProjectState(options);
  const selected = projectInput ? findProject(state.projects, projectInput) : null;
  if (projectInput && !selected) throw new Error(`Unknown project: ${projectInput}`);
  const scanLimit = selected ? 1_000 : limit;
  const raw = await withServer(options, async (client) => {
    const found = [];
    let cursor = null;
    while (found.length < scanLimit) {
      const page = await client.request('thread/list', {
        archived,
        cursor,
        limit: Math.min(100, scanLimit - found.length),
        sortKey: 'updated_at',
      });
      found.push(...(Array.isArray(page?.data) ? page.data : []));
      cursor = page?.nextCursor;
      if (!cursor || page?.data?.length === 0) break;
    }
    return found;
  });

  const enriched = raw.map((thread) => {
    const assignedId = state.assignments[thread.id]?.projectId;
    const assigned = state.projects.find((project) => project.id === assignedId) ?? null;
    const cwdMatch = projectForCwd(state.projects, thread.cwd);
    const project = assigned ?? cwdMatch;
    return {
      id: thread.id,
      name: thread.name ?? null,
      preview: thread.preview ?? null,
      status: thread.status ?? null,
      cwd: thread.cwd ?? null,
      createdAt: thread.createdAt ?? null,
      updatedAt: thread.updatedAt ?? null,
      projectId: project?.id ?? null,
      projectName: project?.name ?? null,
      projectMatch: assigned ? 'assignment' : cwdMatch ? 'cwd' : null,
    };
  });
  return (selected ? enriched.filter((thread) => thread.projectId === selected.id) : enriched).slice(0, limit);
}

export async function newProjectThread({
  project: projectInput,
  prompt,
  create = false,
  timeoutMs = 120_000,
  ...options
} = {}) {
  const resolved = await resolveProject(projectInput, { ...options, create, timeoutMs: Math.min(timeoutMs, 30_000) });
  const root = path.resolve(resolved.project.rootPaths[0]);
  const created = await runNewThread({ ...options, prompt, cwd: root, timeoutMs });
  const listed = await listAppThreads({ ...options, limit: 1_000, project: resolved.project.id });
  const visible = listed.find((thread) => thread.id === created.threadId) ?? null;
  return {
    ...created,
    project: resolved.project,
    projectRegistered: resolved.registered,
    verifiedInThreadList: Boolean(visible),
    projectGrouping: visible ? {
      projectId: visible.projectId,
      projectName: visible.projectName,
      basis: visible.projectMatch,
      explicitAssignment: visible.projectMatch === 'assignment',
    } : null,
    note: visible?.projectMatch === 'cwd'
      ? 'No safe app-owned explicit assignment API was available; project grouping was inferred from the thread cwd.'
      : null,
  };
}

export async function archiveAppThread(threadId, options = {}) {
  return withServer(options, (client) => client.request('thread/archive', { threadId }));
}
