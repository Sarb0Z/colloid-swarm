import { readdir, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { load } from 'js-yaml';
import type { SecurityTemplate } from './types.js';

export function bundledAssetDirectory(name: 'templates' | 'wordlists'): string {
  const moduleDirectory = dirname(fileURLToPath(import.meta.url));
  const bundled = join(moduleDirectory, name);
  if (existsSync(bundled)) return bundled;
  return join(moduleDirectory, '..', '..', '..', name);
}

export async function loadBundledTemplates(): Promise<SecurityTemplate[]> {
  const directory = bundledAssetDirectory('templates');
  const entries = (await readdir(directory)).filter((name) => /\.ya?ml$/i.test(name)).sort();
  const templates: SecurityTemplate[] = [];
  for (const entry of entries) {
    const parsed: unknown = load(await readFile(join(directory, entry), 'utf8'));
    if (isTemplate(parsed)) templates.push(parsed);
  }
  return templates;
}

export async function loadCommonPaths(): Promise<string[]> {
  const path = join(bundledAssetDirectory('wordlists'), 'common-paths.txt');
  return (await readFile(path, 'utf8'))
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.startsWith('/') && !line.startsWith('//'));
}

function isTemplate(value: unknown): value is SecurityTemplate {
  if (!value || typeof value !== 'object') return false;
  const candidate = value as Partial<SecurityTemplate>;
  return (
    typeof candidate.id === 'string' &&
    !!candidate.info &&
    typeof candidate.info.name === 'string' &&
    Array.isArray(candidate.requests)
  );
}
