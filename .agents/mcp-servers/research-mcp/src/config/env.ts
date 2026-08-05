const integer = (name: string, fallback: number, minimum: number, maximum: number): number => {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} to ${maximum}`);
  }
  return value;
};

// Unpaywall requires a real mailbox and rejects placeholders outright; Crossref
// grades the same address into its polite pool. One knob feeds both, so a
// placeholder here degrades two services silently. Refuse it instead.
const PLACEHOLDER_DOMAINS = new Set([
  'example.com', 'example.org', 'example.net', 'test.com', 'email.com', 'domain.com',
]);

const contactEmail = (): string | null => {
  const raw = (process.env.RESEARCH_MCP_CONTACT_EMAIL ?? '').trim();
  if (!raw) return null;
  const match = /^[^\s@]+@([^\s@]+\.[^\s@]+)$/.exec(raw);
  if (!match) throw new Error('RESEARCH_MCP_CONTACT_EMAIL is not an email address');
  const domain = match[1]?.toLowerCase() ?? '';
  if (PLACEHOLDER_DOMAINS.has(domain)) {
    throw new Error(
      'RESEARCH_MCP_CONTACT_EMAIL must be a real mailbox — Unpaywall rejects placeholder domains',
    );
  }
  return raw;
};

export interface RuntimeConfig {
  contactEmail: string | null;
  userAgent: string;
  requestTimeoutMs: number;
  maxBodyBytes: number;
  maxRedirects: number;
  minHostIntervalMs: number;
}

export const VERSION = '0.1.0';

export function getConfig(): RuntimeConfig {
  const email = contactEmail();
  return {
    contactEmail: email,
    // Self-identifying, with a contact when one is configured. Research reads
    // are attributable; nothing here pretends to be a consumer browser.
    userAgent: `colloid-research-mcp/${VERSION} (+https://github.com/colloid-swarm${email ? `; mailto:${email}` : ''})`,
    requestTimeoutMs: integer('RESEARCH_MCP_REQUEST_TIMEOUT_MS', 20_000, 1_000, 60_000),
    maxBodyBytes: integer('RESEARCH_MCP_MAX_BODY_BYTES', 8_388_608, 16_384, 33_554_432),
    maxRedirects: integer('RESEARCH_MCP_MAX_REDIRECTS', 5, 0, 10),
    minHostIntervalMs: integer('RESEARCH_MCP_MIN_HOST_INTERVAL_MS', 350, 0, 10_000),
  };
}
