import { mkdir } from 'node:fs/promises';
import { build } from 'esbuild';

await mkdir('dist/web', { recursive: true });

await build({
  entryPoints: ['src/web/app.ts'],
  bundle: true,
  format: 'esm',
  target: 'es2020',
  sourcemap: true,
  outfile: 'dist/web/app.js',
});

await build({
  entryPoints: ['src/web/sw.ts'],
  bundle: true,
  format: 'iife',
  target: 'es2020',
  outfile: 'dist/web/sw.js',
});
