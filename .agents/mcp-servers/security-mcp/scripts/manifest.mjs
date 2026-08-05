import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { join, relative } from 'node:path';

export async function createBuildManifest(directory) {
  const files = await outputFiles(directory);
  const hashes = {};
  for (const path of files) {
    const name = relative(directory, path);
    hashes[name] = createHash('sha256').update(await readFile(path)).digest('hex');
  }
  return { algorithm: 'sha256', files: hashes };
}

async function outputFiles(directory) {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name === '.build-manifest.json') continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) result.push(...(await outputFiles(path)));
    else result.push(path);
  }
  return result.sort((left, right) => left.localeCompare(right));
}
