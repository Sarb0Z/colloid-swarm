import { readdir, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const MARKER = 'node_modules/';
const LICENSE_FILE = /^(licen[cs]e|copying)([.-].*)?$/i;

// A bundled input such as ../x/node_modules/@scope/pkg/lib/a.js belongs to the
// package named after the last node_modules/ segment. Returns that package's
// directory, so a linked node_modules resolves like a real one.
function packageDirectory(root, input) {
  const at = input.lastIndexOf(MARKER);
  if (at === -1) return undefined;
  const parts = input.slice(at + MARKER.length).split('/');
  const nameLength = parts[0].startsWith('@') ? 2 : 1;
  return resolve(root, input.slice(0, at + MARKER.length), ...parts.slice(0, nameLength));
}

function licenseId(manifest) {
  const field = manifest.license ?? manifest.licenses;
  if (typeof field === 'string') return field;
  if (Array.isArray(field)) return field.map((entry) => entry.type ?? entry).join(' OR ');
  return field?.type ?? 'UNKNOWN';
}

async function noticeSection(directory) {
  const manifest = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'));
  const files = (await readdir(directory, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && LICENSE_FILE.test(entry.name))
    .map((entry) => entry.name)
    .sort();
  const texts = [];
  for (const file of files) texts.push((await readFile(join(directory, file), 'utf8')).trim());
  const id = licenseId(manifest);
  return {
    name: manifest.name,
    version: manifest.version,
    text: [
      `${manifest.name}@${manifest.version}`,
      `License: ${id}`,
      '',
      texts.length > 0
        ? texts.join('\n\n')
        : `No licence file ships in the package; its package.json declares the licence "${id}".`,
    ].join('\n'),
  };
}

// One section per bundled package, sorted by name and version, with the full
// text of each licence file the package ships. `metafile` is esbuild's result
// for a build run with absWorkingDir `root`.
export async function createNotices(root, metafile) {
  const directories = new Set();
  for (const input of Object.keys(metafile.inputs)) {
    const directory = packageDirectory(root, input);
    if (directory) directories.add(directory);
  }
  const sections = await Promise.all([...directories].map(noticeSection));
  sections.sort(
    (left, right) =>
      left.name.localeCompare(right.name, 'en') || left.version.localeCompare(right.version, 'en'),
  );
  const rule = '='.repeat(72);
  return `${[
    'Third-party software bundled in server.js',
    ...sections.map((section) => `${rule}\n${section.text}`),
  ].join('\n\n')}\n`;
}
