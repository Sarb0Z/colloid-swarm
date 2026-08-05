import { chmod, cp, mkdir, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { createBuildManifest } from './manifest.mjs';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const outArgument = process.argv.find((argument) => argument.startsWith('--outdir='));
const outDirectory = outArgument ? resolve(outArgument.slice('--outdir='.length)) : join(root, 'dist');

await rm(outDirectory, { recursive: true, force: true });
await mkdir(outDirectory, { recursive: true });
await build({
  entryPoints: [join(root, 'src', 'server.ts')],
  outfile: join(outDirectory, 'server.js'),
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node20',
  sourcemap: false,
  minify: false,
  legalComments: 'none',
});
await chmod(join(outDirectory, 'server.js'), 0o755);
await cp(join(root, 'templates'), join(outDirectory, 'templates'), { recursive: true });
await cp(join(root, 'wordlists'), join(outDirectory, 'wordlists'), { recursive: true });

const manifest = await createBuildManifest(outDirectory);
await writeFile(
  join(outDirectory, '.build-manifest.json'),
  `${JSON.stringify(manifest, null, 2)}\n`,
);
