import { execFile } from 'node:child_process';
import { readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { mkdtemp } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createBuildManifest } from './manifest.mjs';

const execFileAsync = promisify(execFile);
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const distArgument = process.argv.find((argument) => argument.startsWith('--dist='));
const trackedDirectory = distArgument
  ? resolve(distArgument.slice('--dist='.length))
  : join(root, 'dist');
const temporary = await mkdtemp(join(tmpdir(), 'research-mcp-build-'));
try {
  const tracked = JSON.parse(
    await readFile(join(trackedDirectory, '.build-manifest.json'), 'utf8'),
  );
  const current = await createBuildManifest(trackedDirectory);
  if (JSON.stringify(tracked) !== JSON.stringify(current)) {
    throw new Error('Tracked dist content does not match its build manifest');
  }
  await execFileAsync(process.execPath, [join(root, 'scripts', 'build.mjs'), `--outdir=${temporary}`]);
  const rebuilt = JSON.parse(await readFile(join(temporary, '.build-manifest.json'), 'utf8'));
  if (JSON.stringify(tracked) !== JSON.stringify(rebuilt)) {
    throw new Error('Tracked dist does not match a clean deterministic build');
  }
} finally {
  await rm(temporary, { recursive: true, force: true });
}
