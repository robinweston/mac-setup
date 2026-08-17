#!/usr/bin/env node
import process from 'node:process';
import { DEFAULT_APPROVAL_POLICY } from '../lib/app-server.mjs';
import {
  addProject,
  findProjects,
  readProjectState,
} from '../lib/projects.mjs';
import { archiveProjectThreads, listAppThreads, newProjectThread } from '../lib/threads.mjs';

const HELP = `codex-desktop-cli — Codex Desktop project/thread CLI

Usage:
  codex-desktop-cli projects list [--json]
  codex-desktop-cli projects add PATH [--create] [--timeout MS] [--json]
  codex-desktop-cli projects archive-threads ID|PATH [--dry-run] [--json]
  codex-desktop-cli threads list [--project ID|PATH] [--limit N] [--archived] [--json]
  codex-desktop-cli threads new --project ID|PATH --prompt TEXT [--create] [--approval-policy POLICY] [--sandbox MODE] [--add-dir PATH] [--network-access] [--timeout MS] [--json]

Environment:
  CODEX_HOME         Codex state home (default: ~/.codex)
  CODEX_BIN          codex binary override (prefers ChatGPT.app's bundled binary)
  CODEX_DESKTOP_APP  ChatGPT.app path override (default: /Applications/ChatGPT.app)

Project registration is delegated to ChatGPT.app via macOS open. Thread operations
use the supported codex app-server JSONL interface. Project metadata is never
modified by this tool.
`;

function parseArgs(argv) {
  const [noun, verb, ...tokens] = argv;
  const options = { _: [] };
  const boolean = new Set([
    'json',
    'archived',
    'create',
    'dry-run',
    'help',
    'network-access',
  ]);
  const repeatable = new Set(['add-dir']);
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (!token.startsWith('--')) {
      options._.push(token);
      continue;
    }
    const [key, inline] = token.slice(2).split('=', 2);
    if (boolean.has(key)) {
      options[key] = true;
      continue;
    }
    const value = inline ?? tokens[++i];
    if (value == null || value.startsWith('--')) throw new Error(`Missing value for --${key}`);
    if (repeatable.has(key)) {
      (options[key] ??= []).push(value);
    } else {
      options[key] = value;
    }
  }
  return { noun, verb, options };
}

function integerOption(options, name, fallback) {
  if (options[name] == null) return fallback;
  const value = Number(options[name]);
  if (!Number.isInteger(value) || value < 1) throw new Error(`--${name} must be an integer >= 1`);
  return value;
}

function required(options, name, fallback) {
  const value = options[name] ?? fallback;
  if (typeof value !== 'string' || value.trim() === '') throw new Error(`--${name} is required`);
  return value;
}

function output(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

async function run(noun, verb, options) {
  const timeoutMs = integerOption(options, 'timeout', 120_000);
  const common = {
    timeoutMs,
    codexBin: options['codex-bin'],
    statePath: options['state-path'],
    appPath: options['app-path'],
  };

  if (noun === 'projects' && verb === 'list') {
    const { projects } = await readProjectState(common);
    output({ projects });
    return;
  }

  if (noun === 'projects' && verb === 'add') {
    const projectPath = options.path ?? options._[0];
    if (!projectPath) throw new Error('projects add requires PATH');
    const result = await addProject(projectPath, { ...common, create: Boolean(options.create) });
    output({ ok: true, ...result });
    return;
  }

  if (noun === 'projects' && verb === 'archive-threads') {
    const projectInput = options.path ?? options._[0];
    if (!projectInput) throw new Error('projects archive-threads requires ID or PATH');
    const state = await readProjectState(common);
    const projects = findProjects(state.projects, projectInput);
    if (projects.length === 0) {
      output({ ok: true, projects: [], threads: { threadCount: 0, archiveRootCount: 0 } });
      return;
    }
    const threads = await archiveProjectThreads(state.projects, projects, {
      ...common,
      state,
      dryRun: Boolean(options['dry-run']),
    });
    output({
      ok: true,
      dryRun: Boolean(options['dry-run']),
      projects,
      threads,
    });
    return;
  }

  if (noun === 'threads' && verb === 'list') {
    const threads = await listAppThreads({
      ...common,
      project: options.project,
      archived: Boolean(options.archived),
      limit: integerOption(options, 'limit', 20),
    });
    output({ threads });
    return;
  }

  if (noun === 'threads' && verb === 'new') {
    const result = await newProjectThread({
      ...common,
      project: required(options, 'project'),
      prompt: required(options, 'prompt', options.text),
      create: Boolean(options.create),
      approvalPolicy: options['approval-policy'] ?? DEFAULT_APPROVAL_POLICY,
      sandbox: options.sandbox ?? 'workspace-write',
      writableRoots: options['add-dir'] ?? [],
      networkAccess: Boolean(options['network-access']),
      model: options.model,
      effort: options['reasoning-effort'],
    });
    output(result);
    if (!result.ok || !result.verifiedInThreadList) process.exitCode = 2;
    return;
  }

  throw new Error(`Unknown command: ${[noun, verb].filter(Boolean).join(' ') || '(missing)'}`);
}

const { noun, verb, options } = parseArgs(process.argv.slice(2));
if (!noun || noun === 'help' || noun === '--help' || options.help) {
  process.stdout.write(HELP);
  process.exit(0);
}

run(noun, verb, options).catch((error) => {
  process.stderr.write(`codex-desktop-cli: ${error.message}\n`);
  if (error.details) process.stderr.write(`${JSON.stringify(error.details, null, 2)}\n`);
  process.exitCode = 1;
});
