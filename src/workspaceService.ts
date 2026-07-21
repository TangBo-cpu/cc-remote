import { execFile } from 'node:child_process';
import { open, readdir, realpath, stat } from 'node:fs/promises';
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const MAX_FILE_BYTES = 768 * 1024;
const MAX_GIT_OUTPUT_BYTES = 8 * 1024 * 1024;
const GIT_TIMEOUT_MS = 8000;
const MAX_FALLBACK_FILES = 5000;
const FALLBACK_IGNORES = new Set(['.git', 'node_modules', 'build', 'dist', '.dart_tool']);

export type WorkspaceChange = {
  path: string;
  previousPath?: string;
  staged?: string;
  unstaged?: string;
};

export type WorkspaceSnapshot = {
  rootName: string;
  gitAvailable: boolean;
  branch?: string;
  files: string[];
  changes: WorkspaceChange[];
};

export type WorkspaceFile = {
  path: string;
  content: string;
  size: number;
  truncated: boolean;
};

export class WorkspaceService {
  private gitRepositoryPromise?: Promise<boolean>;
  private snapshotPromise?: Promise<WorkspaceSnapshot>;

  constructor(readonly rootDir: string) {}

  snapshot(): Promise<WorkspaceSnapshot> {
    if (this.snapshotPromise) return this.snapshotPromise;
    const pending = this.buildSnapshot().finally(() => {
      if (this.snapshotPromise === pending) this.snapshotPromise = undefined;
    });
    this.snapshotPromise = pending;
    return pending;
  }

  private async buildSnapshot(): Promise<WorkspaceSnapshot> {
    const gitAvailable = await this.isGitRepository();
    if (!gitAvailable) {
      return {
        rootName: basename(this.rootDir),
        gitAvailable: false,
        files: await listFilesFallback(this.rootDir),
        changes: [],
      };
    }

    const [filesRaw, statusRaw, branchRaw] = await Promise.all([
      this.git(['ls-files', '-co', '--exclude-standard', '-z']),
      this.git(['status', '--porcelain=v1', '-z']),
      this.git(['branch', '--show-current']),
    ]);

    return {
      rootName: basename(this.rootDir),
      gitAvailable: true,
      branch: branchRaw.trim() || undefined,
      files: filesRaw.split('\0').filter(Boolean).sort(comparePaths),
      changes: parseGitStatus(statusRaw),
    };
  }

  async readFile(relativePath: string): Promise<WorkspaceFile> {
    const safePath = normalizeRelative(relativePath);
    await this.assertBrowsablePath(safePath);
    const candidate = resolveWorkspacePath(this.rootDir, safePath);
    const actual = await realpath(candidate);
    assertInsideRoot(this.rootDir, actual);
    const info = await stat(actual);
    if (!info.isFile()) throw new Error('not_a_file');

    const bytesToRead = Math.min(info.size, MAX_FILE_BYTES);
    const handle = await open(actual, 'r');
    try {
      const buffer = Buffer.alloc(bytesToRead);
      const { bytesRead } = await handle.read(buffer, 0, bytesToRead, 0);
      const data = buffer.subarray(0, bytesRead);
      if (data.includes(0)) throw new Error('binary_file');
      return {
        path: safePath,
        content: decodeWorkspaceText(data, info.size > MAX_FILE_BYTES),
        size: info.size,
        truncated: info.size > MAX_FILE_BYTES,
      };
    } finally {
      await handle.close();
    }
  }

  async diff(relativePath: string, staged: boolean): Promise<string> {
    const safePath = normalizeRelative(relativePath);
    await this.assertBrowsablePath(safePath);
    resolveWorkspacePath(this.rootDir, safePath);
    return this.git([
      'diff',
      '--no-ext-diff',
      '--no-textconv',
      '--no-color',
      '--unified=3',
      ...(staged ? ['--cached'] : []),
      '--',
      literalPathspec(safePath),
    ]);
  }

  private isGitRepository(): Promise<boolean> {
    if (this.gitRepositoryPromise) return this.gitRepositoryPromise;
    const pending = this.git(['rev-parse', '--is-inside-work-tree'])
      .then(output => output.trim() === 'true')
      .catch(async error => {
        if (await hasGitMarker(this.rootDir)) throw error;
        return false;
      })
      .catch(error => {
        if (this.gitRepositoryPromise === pending) this.gitRepositoryPromise = undefined;
        throw error;
      });
    this.gitRepositoryPromise = pending;
    return pending;
  }

  private async assertBrowsablePath(safePath: string): Promise<void> {
    if (safePath === '.git' || safePath.startsWith('.git/')) {
      throw new Error('file_not_browsable');
    }
    if (!(await this.isGitRepository())) {
      if (safePath.split('/').some(segment => FALLBACK_IGNORES.has(segment))) {
        throw new Error('file_not_browsable');
      }
      return;
    }
    const output = await this.git([
      'ls-files',
      '-co',
      '--exclude-standard',
      '-z',
      '--',
      literalPathspec(safePath),
    ]);
    if (!output.split('\0').includes(safePath)) throw new Error('file_not_browsable');
  }

  private async git(args: string[]): Promise<string> {
    const result = await execFileAsync('git', ['-C', this.rootDir, ...args], {
      encoding: 'utf8',
      maxBuffer: MAX_GIT_OUTPUT_BYTES,
      timeout: GIT_TIMEOUT_MS,
      killSignal: 'SIGTERM',
      windowsHide: true,
    });
    return result.stdout;
  }
}

export function parseGitStatus(raw: string): WorkspaceChange[] {
  const records = raw.split('\0');
  const changes: WorkspaceChange[] = [];
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (!record || record.length < 4) continue;
    const x = record[0];
    const y = record[1];
    const path = record.slice(3);
    const renamed = x === 'R' || x === 'C' || y === 'R' || y === 'C';
    const previousPath = renamed ? records[++index] || undefined : undefined;
    changes.push({
      path,
      ...(previousPath ? { previousPath } : {}),
      ...(x !== ' ' && x !== '?' ? { staged: x } : {}),
      ...(y !== ' ' ? { unstaged: y } : {}),
    });
  }
  return changes.sort((a, b) => comparePaths(a.path, b.path));
}

export function normalizeRelative(input: string): string {
  const normalized = input.replaceAll('\\', '/').replace(/^\.\//, '');
  if (!normalized || isAbsolute(input) || normalized.startsWith('/') || normalized.split('/').includes('..')) {
    throw new Error('invalid_path');
  }
  return normalized;
}

function resolveWorkspacePath(rootDir: string, input: string): string {
  const normalized = normalizeRelative(input);
  const candidate = resolve(rootDir, ...normalized.split('/'));
  assertInsideRoot(rootDir, candidate);
  return candidate;
}

function assertInsideRoot(rootDir: string, candidate: string): void {
  const root = resolve(rootDir);
  const child = resolve(candidate);
  const relativePath = relative(root, child);
  if (relativePath === '' || (!relativePath.startsWith(`..${sep}`) && relativePath !== '..' && !isAbsolute(relativePath))) {
    return;
  }
  throw new Error('path_outside_workspace');
}

async function listFilesFallback(rootDir: string): Promise<string[]> {
  const files: string[] = [];
  const visit = async (dir: string): Promise<void> => {
    if (files.length >= MAX_FALLBACK_FILES) return;
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (files.length >= MAX_FALLBACK_FILES) return;
      if (FALLBACK_IGNORES.has(entry.name)) continue;
      const absolute = resolve(dir, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        await visit(absolute);
      } else if (entry.isFile()) {
        files.push(relative(rootDir, absolute).replaceAll('\\', '/'));
      }
    }
  };
  await visit(rootDir);
  return files.sort(comparePaths);
}

function comparePaths(a: string, b: string): number {
  return a.localeCompare(b, 'en', { sensitivity: 'base' });
}

function literalPathspec(path: string): string {
  return `:(literal)${path}`;
}

function decodeWorkspaceText(data: Buffer, truncated: boolean): string {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(data);
  } catch {
    if (truncated) {
      for (let trim = 1; trim <= 3 && trim < data.length; trim += 1) {
        try {
          return new TextDecoder('utf-8', { fatal: true }).decode(data.subarray(0, data.length - trim));
        } catch {
          // Try the previous UTF-8 boundary.
        }
      }
    }
    throw new Error('binary_file');
  }
}

async function hasGitMarker(startDir: string): Promise<boolean> {
  let current = resolve(startDir);
  while (true) {
    try {
      await stat(resolve(current, '.git'));
      return true;
    } catch {
      const parent = dirname(current);
      if (parent === current) return false;
      current = parent;
    }
  }
}
