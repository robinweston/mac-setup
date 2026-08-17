import path from 'node:path';
import { AppServerClient, runNewThread } from './app-server.mjs';
import { findProject, projectForCwd, readProjectState, resolveProject } from './projects.mjs';

export const ALL_THREAD_SOURCE_KINDS = [
  'cli',
  'vscode',
  'exec',
  'appServer',
  'subAgent',
  'subAgentReview',
  'subAgentCompact',
  'subAgentThreadSpawn',
  'subAgentOther',
  'unknown',
];

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

async function listThreadPage(client, archived, cursor) {
  return client.request('thread/list', {
    archived,
    cursor,
    limit: 100,
    sortKey: 'updated_at',
    sourceKinds: ALL_THREAD_SOURCE_KINDS,
  });
}

export async function listAllAppThreads(client, archived) {
  const threads = [];
  let cursor = null;

  do {
    const page = await listThreadPage(client, archived, cursor);
    threads.push(...(Array.isArray(page?.data) ? page.data : []));
    cursor = page?.nextCursor ?? null;
  } while (cursor);

  return threads;
}

export function selectProjectThreads(threads, projects, state, selectedProjects) {
  const selectedIds = new Set(selectedProjects.map((project) => project.id));

  return threads.filter((thread) => {
    const assignedId = state.assignments[thread.id]?.projectId;
    if (assignedId) return selectedIds.has(assignedId);
    return selectedIds.has(projectForCwd(projects, thread.cwd)?.id);
  });
}

function rootThreads(threads) {
  const selectedIds = new Set(threads.map((thread) => thread.id));
  return threads.filter(
    (thread) => !thread.parentThreadId || !selectedIds.has(thread.parentThreadId),
  );
}

export async function archiveProjectThreads(projects, selectedProjects, options = {}) {
  const state = options.state ?? (await readProjectState(options));

  const archive = async (client) => {
    const active = await listAllAppThreads(client, false);
    const selected = selectProjectThreads(
      active,
      projects,
      state,
      selectedProjects,
    );
    const roots = rootThreads(selected);

    if (!options.dryRun) {
      for (const thread of roots) {
        await client.request('thread/archive', { threadId: thread.id });
      }
    }

    return {
      threadCount: selected.length,
      archiveRootCount: roots.length,
      threadIds: selected.map((thread) => thread.id),
      archiveRootIds: roots.map((thread) => thread.id),
    };
  };

  if (options.client) return archive(options.client);
  return withServer(options, archive);
}
