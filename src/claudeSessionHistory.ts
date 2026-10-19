import { appendFile, open, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { NativeHistory, NativeMessage } from './nativeHistory.js';

export const CLAUDE_APP_ENTRYPOINT = 'cc-app';
const SDK_ENTRYPOINTS = new Set(['sdk-cli', 'sdk-ts', 'sdk-py']);

export class ClaudeHistoryReader {
  private cache = new Map<string, { path: string; stamp: string; history: NativeHistory }>();

  constructor(private readonly projectsDir = join(
    process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects',
  )) {}

  forget(sessionId: string): void {
    this.cache.delete(sessionId);
  }

  async read(sessionId: string): Promise<NativeHistory | null> {
    if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(sessionId)) return null;
    const cached = this.cache.get(sessionId);
    let path = cached?.path;
    let info;
    try {
      if (path) info = await stat(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      this.cache.delete(sessionId);
      path = undefined;
    }
    path ??= await findSessionTranscript(this.projectsDir, sessionId + '.jsonl') ?? undefined;
    if (!path) return null;
    info ??= await stat(path);
    const stamp = [info.size, info.mtimeMs, info.ctimeMs].join(':');
    // shortcut: JSONL has no process liveness signal; use recent writes until Claude exposes one.
    const withRecentActivity = (history: NativeHistory): NativeHistory => ({
      ...history, running: history.running && Date.now() - info.mtimeMs < 30_000,
    });
    if (cached?.path === path && cached.stamp === stamp) return withRecentActivity(cached.history);
    const history = parseClaudeHistory(sessionId, await readFile(path, 'utf8'));
    this.cache.set(sessionId, { path, stamp, history });
    return withRecentActivity(history);
  }
}

export function parseClaudeHistory(sessionId: string, source: string): NativeHistory {
  const boundary = source.lastIndexOf('\n') + 1;
  const entries = source.slice(0, boundary).split('\n').filter(line => line.trim()).map(line => {
    const value: unknown = JSON.parse(line);
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new Error('native_history_invalid');
    }
    return value as Record<string, unknown>;
  }).filter(entry => entry.sessionId === sessionId && entry.isSidechain !== true);
  const main = entries.filter(entry => entry.type === 'user' || entry.type === 'assistant');
  let chain = main;
  const last = main.at(-1);
  if (last && typeof last.uuid === 'string' && 'parentUuid' in last) {
    const byId = new Map(entries.filter(entry => typeof entry.uuid === 'string')
      .map(entry => [entry.uuid as string, entry]));
    const visited = new Set<string>();
    chain = [];
    let entry: Record<string, unknown> | undefined = last;
    while (entry && typeof entry.uuid === 'string') {
      if (visited.has(entry.uuid)) throw new Error('native_history_invalid');
      visited.add(entry.uuid);
      chain.push(entry);
      const parent: string | undefined = typeof entry.parentUuid === 'string' ? entry.parentUuid
        : entry.subtype === 'compact_boundary' && typeof entry.logicalParentUuid === 'string'
          ? entry.logicalParentUuid : undefined;
      entry = parent ? byId.get(parent) : undefined;
    }
    chain.reverse();
  }
  const messages: NativeMessage[] = [];
  for (const entry of chain) {
    if ((entry.type !== 'user' && entry.type !== 'assistant')
        || typeof entry.uuid !== 'string' || !entry.uuid
        || entry.isMeta === true || entry.isCompactSummary === true) continue;
    const message = entry.message as Record<string, unknown> | undefined;
    if (!message || typeof message !== 'object') continue;
    const content = message.content;
    if (entry.type === 'user' && Array.isArray(content)
        && content.some(block => block?.type === 'tool_result')) continue;
    let text = typeof content === 'string' ? content : Array.isArray(content)
      ? content.filter(block => block?.type === 'text' && typeof block.text === 'string')
        .map(block => block.text).join('') : '';
    if (!text.trim() && entry.type === 'user' && Array.isArray(content)
        && content.some(block => block?.type === 'image')) text = '[图片]';
    if (!text.trim()) continue;
    const next: NativeMessage = { id: entry.uuid, role: entry.type, text };
    const existing = messages.findIndex(item => item.id === next.id);
    if (existing >= 0) messages[existing] = next;
    else messages.push(next);
  }
  const lastWork = main.filter(entry => entry.isMeta !== true && entry.isCompactSummary !== true).at(-1);
  const lastMessage = lastWork?.message as Record<string, unknown> | undefined;
  const content = lastMessage?.content;
  const running = boundary < source.length || lastWork?.type === 'user'
    || lastMessage?.stop_reason === 'tool_use'
    || (Array.isArray(content) && content.some(block => block?.type === 'tool_use'));
  return { sessionId, messages, running };
}

export async function findSessionTranscript(root: string, fileName: string): Promise<string | null> {
  const pending = [root];
  while (pending.length) {
    const directory = pending.shift()!;
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) pending.push(path);
      else if (entry.isFile() && entry.name === fileName) return path;
    }
  }
  return null;
}

export async function syncClaudeSessionHistory(options: {
  sessionId: string;
  title: string;
  projectsDir?: string;
}): Promise<boolean> {
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(options.sessionId)) return false;
  const root = options.projectsDir ?? join(
    process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects',
  );
  const path = await findSessionTranscript(root, `${options.sessionId}.jsonl`);
  if (!path) return false;
  const original = await readFile(path);
  const updates: { offset: number; before: Buffer; after: Buffer }[] = [];
  let latestTitle: string | undefined;
  let hasMessages = false;
  let lineStart = 0;
  while (lineStart < original.length) {
    const lineEnd = original.indexOf(10, lineStart);
    if (lineEnd < 0) return false;
    const line = original.subarray(lineStart, lineEnd);
    try {
      const entry = JSON.parse(line.toString('utf8')) as Record<string, unknown>;
      if (entry.sessionId === options.sessionId && entry.isSidechain !== true) {
        if (entry.type === 'user' || entry.type === 'assistant') hasMessages = true;
        if (entry.type === 'custom-title' && typeof entry.customTitle === 'string') {
          latestTitle = entry.customTitle;
        }
        if (typeof entry.entrypoint === 'string' && SDK_ENTRYPOINTS.has(entry.entrypoint)) {
          const span = topLevelStringSpan(line, 'entrypoint');
          if (span) {
            const before = line.subarray(span.start, span.end);
            const replacement = JSON.stringify(CLAUDE_APP_ENTRYPOINT).padEnd(before.length, ' ');
            updates.push({
              offset: lineStart + span.start,
              before,
              after: Buffer.from(replacement),
            });
          }
        }
      }
    } catch {}
    lineStart = lineEnd + 1;
  }
  const title = options.title.trim();
  const needsTitle = hasMessages && title.length > 0 && latestTitle !== title;
  if (updates.length === 0 && !needsTitle) return false;

  const handle = await open(path, 'r+');
  try {
    for (const update of updates) {
      const current = Buffer.alloc(update.before.length);
      await handle.read(current, 0, current.length, update.offset);
      if (!current.equals(update.before)) return false;
    }
    // Keep a copy before changing metadata; never truncate a live transcript.
    try {
      await writeFile(`${path}.cc-remote-history.bak`, original, { flag: 'wx', mode: 0o600 });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
    }
    for (const update of updates) {
      await handle.write(update.after, 0, update.after.length, update.offset);
    }
    if (needsTitle) {
      await appendFile(path, JSON.stringify({
        type: 'custom-title',
        customTitle: title,
        sessionId: options.sessionId,
      }) + '\n');
    }
  } finally {
    await handle.close();
  }
  return true;
}

function topLevelStringSpan(line: Buffer, key: string): { start: number; end: number } | undefined {
  let depth = 0;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (character === 123 || character === 91) depth += 1;
    else if (character === 125 || character === 93) depth -= 1;
    else if (character === 34) {
      const start = index;
      index += 1;
      while (index < line.length && line[index] !== 34) {
        index += line[index] === 92 ? 2 : 1;
      }
      if (depth !== 1 || line.subarray(start + 1, index).toString('utf8') !== key) continue;
      let valueStart = index + 1;
      while (line[valueStart] === 32 || line[valueStart] === 9) valueStart += 1;
      if (line[valueStart] !== 58) continue;
      valueStart += 1;
      while (line[valueStart] === 32 || line[valueStart] === 9) valueStart += 1;
      if (line[valueStart] !== 34) continue;
      let valueEnd = valueStart + 1;
      while (valueEnd < line.length && line[valueEnd] !== 34) {
        valueEnd += line[valueEnd] === 92 ? 2 : 1;
      }
      return { start: valueStart, end: valueEnd + 1 };
    }
  }
  return undefined;
}
