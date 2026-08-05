import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const lock = JSON.parse(await readFile(resolve(root, 'package-lock.json'), 'utf8'));
const components = Object.entries(lock.packages)
  .filter(([path, item]) => path && item.version)
  .map(([path, item]) => ({
    type: 'library',
    name: item.name ?? path.replace(/^node_modules\//, ''),
    version: item.version,
    ...(item.license ? { licenses: [{ license: { id: item.license } }] } : {}),
    properties: [{ name: 'npm:path', value: path }],
  }))
  .sort((left, right) => left.name.localeCompare(right.name) || left.version.localeCompare(right.version));
const sbom = {
  bomFormat: 'CycloneDX',
  specVersion: '1.6',
  version: 1,
  metadata: {
    component: {
      type: 'application',
      name: '@colloid-swarm/security-mcp',
      version: '0.10.0-colloid.1',
    },
  },
  components,
};
await writeFile(resolve(root, 'sbom.cdx.json'), `${JSON.stringify(sbom, null, 2)}\n`);
