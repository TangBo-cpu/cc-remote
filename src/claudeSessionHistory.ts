import { appendFile, open, readFile, readdir, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const CLAUDE_APP_ENTRYPOINT = 'cc-app';
const SDK_ENTRYPOINTS = new Set(['sdk-cli', 'sdk-ts', 'sdk-py']);

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
