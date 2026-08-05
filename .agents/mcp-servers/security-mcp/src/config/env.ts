const integer = (name: string, fallback: number, minimum: number, maximum: number): number => {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} to ${maximum}`);
  }
  return value;
};

const allowedHosts = (): ReadonlySet<string> => {
  const result = new Set<string>();
  for (const raw of (process.env.SECURITY_MCP_ALLOWED_HOSTS ?? '').split(',')) {
    const host = raw.trim().toLowerCase().replace(/\.$/, '');
    if (!host) continue;
    if (host.includes('*') || host.includes('/') || host.includes(':')) {
      throw new Error('SECURITY_MCP_ALLOWED_HOSTS accepts exact DNS hostnames only');
    }
    result.add(host);
  }
  return result;
};

export interface RuntimeConfig {
  allowedHosts: ReadonlySet<string>;
  requestTimeoutMs: number;
  maxRequests: number;
  maxDepth: number;
  maxRedirects: number;
  maxBodyBytes: number;
}

export function getConfig(): RuntimeConfig {
  return {
    allowedHosts: allowedHosts(),
    requestTimeoutMs: integer('SECURITY_MCP_REQUEST_TIMEOUT_MS', 10_000, 250, 30_000),
    maxRequests: integer('SECURITY_MCP_MAX_REQUESTS', 25, 1, 100),
    maxDepth: integer('SECURITY_MCP_MAX_DEPTH', 2, 0, 3),
    maxRedirects: integer('SECURITY_MCP_MAX_REDIRECTS', 3, 0, 5),
    maxBodyBytes: integer('SECURITY_MCP_MAX_BODY_BYTES', 262_144, 1_024, 1_048_576),
  };
}
