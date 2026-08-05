import { chmod, mkdir, rm, writeFile } from 'node:fs/promises';
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
  // pdf.js probes for an optional native `canvas` binding that only matters for
  // rendering; text extraction never needs it, and bundling a native module is
  // not possible anyway. Everything else ships inside the bundle so `dist` runs
  // from a clone with no install step.
  external: ['canvas'],
  banner: {
    js: "import { createRequire as __createRequire } from 'node:module';\nconst require = __createRequire(import.meta.url);",
  },
});
await chmod(join(outDirectory, 'server.js'), 0o755);

const manifest = await createBuildManifest(outDirectory);
await writeFile(
  join(outDirectory, '.build-manifest.json'),
  `${JSON.stringify(manifest, null, 2)}\n`,
);
