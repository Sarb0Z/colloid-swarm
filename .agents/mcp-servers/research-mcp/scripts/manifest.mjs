import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { join, relative } from 'node:path';

// esbuild writes each module's path into the bundle relative to the build
// directory, resolved through any symlink. Under a node_modules that links
// into another checkout that path grows a prefix such as
// ../../../../repo/.../node_modules/, and the bundle differs by exactly those
// bytes while being the same code. Hashing with the prefix folded back to
// node_modules/ makes the manifest the same for a linked and a real install;
// on a real install the fold is the identity.
const LINKED_PREFIX = /(?:\.\.\/)+(?:[^\s"'`]*?\/)?node_modules\//g;

export function foldLinkedPrefixes(text) {
  return text.replace(LINKED_PREFIX, 'node_modules/');
}

export async function createBuildManifest(directory) {
  const files = await outputFiles(directory);
  const hashes = {};
  for (const path of files) {
    const name = relative(directory, path);
    const content = path.endsWith('.js') || path.endsWith('.map')
      ? Buffer.from(foldLinkedPrefixes(await readFile(path, 'utf8')))
      : await readFile(path);
    hashes[name] = createHash('sha256').update(content).digest('hex');
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
