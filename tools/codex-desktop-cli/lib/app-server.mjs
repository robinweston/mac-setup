import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import readline from 'node:readline';

const DESKTOP_CODEX = '/Applications/ChatGPT.app/Contents/Resources/codex';
export const DEFAULT_APPROVAL_POLICY = 'unlessTrusted';

export function resolveCodexBinary(env = process.env) {
  if (env.CODEX_BIN) return env.CODEX_BIN;
  if (existsSync(DESKTOP_CODEX)) return DESKTOP_CODEX;
  return 'codex';
}

export class AppServerError extends Error {
  constructor(message, details) {
    super(message);
    this.name = 'AppServerError';
    this.details = details;
  }
}

export class AppServerClient {
  constructor({ codexBin = resolveCodexBinary(), cwd = process.cwd(), timeoutMs = 120_000 } = {}) {
    this.codexBin = codexBin;
    this.cwd = cwd;
    this.timeoutMs = timeoutMs;
    this.nextId = 1;
    this.pending = new Map();
    this.notifications = [];
    this.waiters = new Set();
    this.stderr = '';
  }

  async connect() {
    if (this.child) return;
    this.child = spawn(this.codexBin, ['app-server'], {
      cwd: this.cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child.stderr.setEncoding('utf8');
    this.child.stderr.on('data', (chunk) => {
      this.stderr = `${this.stderr}${chunk}`.slice(-16_384);
    });
    this.child.once('error', (error) => this.#failAll(error));
    this.child.once('exit', (code, signal) => {
      if (!this.closing && this.pending.size) {
        this.#failAll(new AppServerError(
          `codex app-server exited before replying (code=${code}, signal=${signal})`,
          this.stderr.trim(),
        ));
      }
    });

    const lines = readline.createInterface({ input: this.child.stdout });
    lines.on('line', (line) => this.#receive(line));
    this.lines = lines;

    await this.request('initialize', {
      clientInfo: { name: 'codex_desktop_cli', title: 'Codex Desktop projects CLI', version: '0.1.0' },
      capabilities: { experimentalApi: true },
    });
    this.notify('initialized', {});
  }

  request(method, params = {}, timeoutMs = this.timeoutMs) {
    if (!this.child?.stdin.writable) throw new AppServerError('app-server is not connected');
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new AppServerError(`${method} timed out after ${timeoutMs}ms`, this.stderr.trim()));
      }, timeoutMs);
      this.pending.set(id, { method, resolve, reject, timer });
      this.#write({ id, method, params });
    });
  }

  notify(method, params = {}) {
    this.#write({ method, params });
  }

  waitFor(predicate, timeoutMs = this.timeoutMs) {
    const existing = this.notifications.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, reject };
      waiter.timer = setTimeout(() => {
        this.waiters.delete(waiter);
        reject(new AppServerError(`app-server event timed out after ${timeoutMs}ms`, this.stderr.trim()));
      }, timeoutMs);
      this.waiters.add(waiter);
    });
  }

  async close() {
    if (!this.child) return;
    this.closing = true;
    this.lines?.close();
    this.child.stdin.end();
    if (this.child.exitCode == null && this.child.signalCode == null) {
      await Promise.race([
        new Promise((resolve) => this.child.once('exit', resolve)),
        new Promise((resolve) => setTimeout(resolve, 750)),
      ]);
    }
    if (this.child.exitCode == null && this.child.signalCode == null) this.child.kill('SIGTERM');
    this.#failAll(new AppServerError('app-server client closed'));
  }

  #write(message) {
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #receive(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.#failAll(new AppServerError(`app-server emitted invalid JSON: ${line.slice(0, 200)}`));
      return;
    }

    if (Object.hasOwn(message, 'id') && !message.method) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timer);
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new AppServerError(
          `${pending.method} failed: ${message.error.message ?? JSON.stringify(message.error)}`,
          message.error,
        ));
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    if (Object.hasOwn(message, 'id') && message.method) {
      this.#write({ id: message.id, error: { code: -32601, message: 'Client request handler unavailable' } });
      return;
    }

    if (message.method) {
      this.notifications.push(message);
      if (this.notifications.length > 2_000) this.notifications.shift();
      for (const waiter of this.waiters) {
        if (!waiter.predicate(message)) continue;
        clearTimeout(waiter.timer);
        this.waiters.delete(waiter);
        waiter.resolve(message);
      }
    }
  }

  #failAll(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    for (const waiter of this.waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.waiters.clear();
  }
}

function idsFrom(result, key) {
  const value = result?.[key] ?? result;
  return value && typeof value === 'object' ? value : {};
}

function completedAgentMessage(client, threadId, turnId) {
  return client.notifications
    .filter((message) => message.method === 'item/completed'
      && message.params?.threadId === threadId
      && message.params?.turnId === turnId
      && message.params?.item?.type === 'agentMessage')
    .map((message) => message.params.item.text)
    .filter((text) => typeof text === 'string')
    .at(-1) ?? '';
}

export async function runNewThread({
  prompt,
  cwd,
  timeoutMs = 120_000,
  codexBin,
  approvalPolicy = DEFAULT_APPROVAL_POLICY,
  sandbox = 'workspace-write',
  model,
  effort,
} = {}) {
  const client = new AppServerClient({ codexBin, cwd, timeoutMs });
  try {
    await client.connect();
    const threadParams = { cwd, approvalPolicy, sandbox };
    if (model) threadParams.model = model;
    const started = idsFrom(await client.request('thread/start', threadParams), 'thread');
    const threadId = started.id;
    if (!threadId) throw new AppServerError('thread/start did not return a thread id', started);

    const turnParams = {
      threadId,
      input: [{ type: 'text', text: prompt }],
      approvalPolicy,
    };
    if (effort) turnParams.effort = effort;
    const turnStarted = idsFrom(await client.request('turn/start', turnParams), 'turn');
    const turnId = turnStarted.id;
    if (!turnId) throw new AppServerError('turn/start did not return a turn id', turnStarted);

    const completed = await client.waitFor((message) => message.method === 'turn/completed'
      && message.params?.threadId === threadId
      && message.params?.turn?.id === turnId, timeoutMs);

    return {
      ok: completed.params?.turn?.status === 'completed',
      transport: 'supported-app-server',
      threadId,
      turnId,
      cwd,
      promptSubmitted: true,
      status: completed.params?.turn?.status ?? null,
      response: completedAgentMessage(client, threadId, turnId),
      error: completed.params?.turn?.error ?? null,
    };
  } finally {
    await client.close();
  }
}
