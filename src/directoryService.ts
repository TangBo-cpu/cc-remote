import { opendir, readdir, realpath, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, parse } from 'node:path';

export type DirectoryEntry = { name: string; path: string };
export type DirectoryListing = {
  path: string | null;
  parentPath: string | null;
  roots: DirectoryEntry[];
  directories: DirectoryEntry[];
  truncated: boolean;
};

export class DirectoryError extends Error {
  constructor(readonly code: string, readonly status: number) {
    super(code);
  }
}

function directoryFailure(error: unknown): DirectoryError {
  if (error instanceof DirectoryError) return error;
  const code = (error as NodeJS.ErrnoException)?.code;
  if (code === 'ENOENT') return new DirectoryError('directory_not_found', 404);
  if (code === 'ENOTDIR') return new DirectoryError('directory_not_directory', 400);
  if (code === 'EACCES' || code === 'EPERM') return new DirectoryError('directory_access_denied', 403);
  if (code === 'EINVAL' || code === 'ENAMETOOLONG' || code === 'ELOOP') {
    return new DirectoryError('directory_path_invalid', 400);
  }
  return new DirectoryError('directory_read_failed', 500);
}

export async function canonicalDirectory(raw: unknown): Promise<string> {
  if (typeof raw !== 'string' || !raw.trim() || raw.includes('\0') || raw.length > 32768
    || !isAbsolute(raw.trim())
    || (process.platform === 'win32' && !/^(?:[a-z]:[\\/]|\\\\[^\\]+\\[^\\]+)/i.test(raw.trim()))) {
    throw new DirectoryError('directory_path_invalid', 400);
  }
  try {
    const path = await realpath(raw.trim());
    if (!(await stat(path)).isDirectory()) throw new DirectoryError('directory_not_directory', 400);
    const directory = await opendir(path);
    await directory.close();
    return path;
  } catch (error) {
    throw directoryFailure(error);
  }
}

export async function browseDirectories(raw?: unknown): Promise<DirectoryListing> {
  if (raw === undefined) {
    const candidates: DirectoryEntry[] = process.platform === 'win32'
      ? Array.from({ length: 26 }, (_, index) => ({
        name: `${String.fromCharCode(65 + index)}:`,
        path: `${String.fromCharCode(65 + index)}:\\`,
      }))
      : [{ name: '/', path: '/' }];
    candidates.push({ name: 'Home', path: homedir() });
    const available = await Promise.all(candidates.map(async entry => {
      try { return { name: entry.name, path: await canonicalDirectory(entry.path) }; }
      catch { return undefined; }
    }));
    const roots = available.filter((entry): entry is DirectoryEntry => entry !== undefined);
    return { path: null, parentPath: null, roots, directories: [], truncated: false };
  }

  const path = await canonicalDirectory(raw);
  try {
    const entries = (await readdir(path, { withFileTypes: true }))
      .filter(entry => entry.isDirectory() || entry.isSymbolicLink())
      .sort((left, right) => left.name.localeCompare(right.name, undefined, { numeric: true, sensitivity: 'base' }));
    const directories: DirectoryEntry[] = [];
    let truncated = false;
    for (const entry of entries) {
      const childPath = join(path, entry.name);
      if (entry.isSymbolicLink()) {
        try { if (!(await stat(childPath)).isDirectory()) continue; }
        catch { continue; }
      }
      if (directories.length >= 500) { truncated = true; break; }
      directories.push({ name: entry.name, path: childPath });
    }
    return {
      path,
      parentPath: path === parse(path).root ? null : dirname(path),
      roots: [], directories, truncated,
    };
  } catch (error) {
    throw directoryFailure(error);
  }
}
