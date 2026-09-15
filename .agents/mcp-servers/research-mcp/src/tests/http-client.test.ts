import { PassThrough } from 'node:stream';
import type { IncomingHttpHeaders, IncomingMessage } from 'node:http';
import { describe, expect, it } from 'vitest';
import type { RuntimeConfig } from '../config/env.js';
import type { Resolver } from '../core/url-policy.js';
import {
  FetchError,
  HttpClient,
  isRetryableStatus,
  parseRetryAfterMs,
} from '../core/http-client.js';

const config = (overrides: Partial<RuntimeConfig> = {}): RuntimeConfig => ({
  contactEmail: null,
  userAgent: 'test',
  requestTimeoutMs: 1_000,
  maxBodyBytes: 1_024 * 1_024,
  maxRedirects: 3,
  minHostIntervalMs: 0,
  retries: 2,
  // Zero delays keep the suite fast; the loop's shape is what is under test,
  // not the wall time it sleeps for.
  retryBaseDelayMs: 0,
  retryMaxDelayMs: 0,
  fetchBudgetMs: 60_000,
  ...overrides,
});

// A routable address: the documentation ranges (203.0.113.0/24 and friends) are
// reserved, and the policy rejects them before the transport is ever reached.
const publicResolver: Resolver = async () => [{ address: '93.184.216.34', family: 4 }];

/** A response object shaped like the one `http.request` yields to its callback. */
function reply(status: number, body = '', headers: IncomingHttpHeaders = {}): IncomingMessage {
  const stream = new PassThrough() as PassThrough & { statusCode: number; headers: IncomingHttpHeaders };
  stream.statusCode = status;
  stream.headers = { 'content-type': 'text/plain', ...headers };
  setImmediate(() => stream.end(body));
  return stream as unknown as IncomingMessage;
}

type Step = IncomingMessage | Error;

/** Drives the retry loop off a scripted queue instead of a socket. */
class ScriptedClient extends HttpClient {
  readonly requested: string[] = [];

  constructor(private readonly steps: Step[], runtime: RuntimeConfig = config()) {
    super(runtime, publicResolver);
  }

  /** Every delay the policy chose, in order, without spending the wall time. */
  readonly slept: number[] = [];

  protected override send(url: URL): Promise<IncomingMessage> {
    this.requested.push(url.toString());
    const step = this.steps.shift();
    if (!step) throw new Error('ScriptedClient ran out of scripted responses');
    return step instanceof Error ? Promise.reject(step) : Promise.resolve(step);
  }

  protected override sleep(ms: number): Promise<void> {
    this.slept.push(ms);
    return Promise.resolve();
  }
}

describe('parseRetryAfterMs', () => {
  it('reads a delta in seconds', () => {
    expect(parseRetryAfterMs('120')).toBe(120_000);
  });

  it('reads an HTTP date as a delta from now', () => {
    const now = Date.parse('2026-01-01T00:00:00Z');
    expect(parseRetryAfterMs('Thu, 01 Jan 2026 00:00:30 GMT', now)).toBe(30_000);
  });

  it('floors a date already in the past at zero rather than going negative', () => {
    const now = Date.parse('2026-01-01T00:01:00Z');
    expect(parseRetryAfterMs('Thu, 01 Jan 2026 00:00:00 GMT', now)).toBe(0);
  });

  it('returns null when absent or unparseable', () => {
    expect(parseRetryAfterMs(undefined)).toBeNull();
    expect(parseRetryAfterMs('soon')).toBeNull();
  });
});

describe('isRetryableStatus', () => {
  it('retries a 429 and any 5xx', () => {
    expect(isRetryableStatus(429)).toBe(true);
    expect(isRetryableStatus(500)).toBe(true);
    expect(isRetryableStatus(503)).toBe(true);
  });

  it('does not retry a 4xx that is the request being rejected', () => {
    expect(isRetryableStatus(403)).toBe(false);
    expect(isRetryableStatus(404)).toBe(false);
  });
});

describe('HttpClient retry', () => {
  it('recovers a 503 on a later attempt', async () => {
    const client = new ScriptedClient([reply(503, 'busy'), reply(200, 'archived page')]);
    const result = await client.fetch('https://example.com/doc');
    expect(result.status).toBe(200);
    expect(result.text).toBe('archived page');
    expect(client.requested).toHaveLength(2);
  });

  it('recovers a transport failure such as a timeout', async () => {
    const client = new ScriptedClient([
      new FetchError('Timed out after 1000ms', 'network'),
      reply(200, 'ok'),
    ]);
    await expect(client.fetch('https://example.com/doc')).resolves.toMatchObject({ text: 'ok' });
    expect(client.requested).toHaveLength(2);
  });

  it('honours Retry-After on a 429', async () => {
    const client = new ScriptedClient([
      reply(429, 'slow down', { 'retry-after': '0' }),
      reply(200, 'ok'),
    ]);
    await expect(client.fetch('https://example.com/doc')).resolves.toMatchObject({ status: 200 });
    expect(client.requested).toHaveLength(2);
  });

  it('spends no extra attempt on a 404, which will never change', async () => {
    const client = new ScriptedClient([reply(404, 'gone')]);
    await expect(client.fetch('https://example.com/doc')).rejects.toMatchObject({
      kind: 'http',
      status: 404,
    });
    expect(client.requested).toHaveLength(1);
  });

  it('gives up after the configured attempts and reports the origin status', async () => {
    const client = new ScriptedClient([reply(503), reply(503), reply(503)]);
    await expect(client.fetch('https://example.com/doc')).rejects.toMatchObject({
      kind: 'http',
      status: 503,
    });
    expect(client.requested).toHaveLength(3);
  });

  it('never retries a policy refusal', async () => {
    const client = new ScriptedClient([]);
    await expect(client.fetch('http://user:pw@example.com/doc')).rejects.toMatchObject({
      kind: 'policy',
    });
    expect(client.requested).toHaveLength(0);
  });

  it('retries within the hop it is on, without replaying earlier redirects', async () => {
    const client = new ScriptedClient([
      reply(302, '', { location: 'https://example.com/final' }),
      reply(503),
      reply(200, 'landed'),
    ]);
    const result = await client.fetch('https://example.com/start');
    expect(result.text).toBe('landed');
    // The redirect is requested once; only the second hop is attempted twice.
    expect(client.requested).toEqual([
      'https://example.com/start',
      'https://example.com/final',
      'https://example.com/final',
    ]);
  });

  it('makes exactly one attempt when retrying is switched off', async () => {
    const client = new ScriptedClient([reply(503)], config({ retries: 0 }));
    await expect(client.fetch('https://example.com/doc')).rejects.toMatchObject({ status: 503 });
    expect(client.requested).toHaveLength(1);
  });
});

describe('HttpClient pacing', () => {
  // Real delays here, so an ignored Retry-After would show up as a backoff.
  const paced = (overrides = {}) =>
    config({ retryBaseDelayMs: 500, retryMaxDelayMs: 8_000, ...overrides });

  it('waits the interval the origin asked for', async () => {
    const client = new ScriptedClient(
      [reply(429, '', { 'retry-after': '1' }), reply(200, 'ok')],
      paced(),
    );
    await client.fetch('https://example.com/doc');
    expect(client.slept).toEqual([1_000]);
  });

  it('caps a hostile Retry-After instead of parking the process', async () => {
    // A day-long interval is either hostile or misconfigured. Either way a
    // research read must not honour it literally.
    const client = new ScriptedClient(
      [reply(503, '', { 'retry-after': '86400' }), reply(200, 'ok')],
      paced(),
    );
    await client.fetch('https://example.com/doc');
    expect(client.slept).toEqual([32_000]); // retryMaxDelayMs * 4
  });

  it('backs off exponentially when the origin names no interval', async () => {
    const client = new ScriptedClient([reply(503), reply(503), reply(200, 'ok')], paced());
    await client.fetch('https://example.com/doc');
    expect(client.slept).toHaveLength(2);
    expect(client.slept[1]).toBeGreaterThan(client.slept[0] ?? 0);
  });

  it('refuses a wait that would outlive the call budget', async () => {
    const client = new ScriptedClient(
      [reply(503, '', { 'retry-after': '86400' }), reply(200, 'ok')],
      paced({ fetchBudgetMs: 5_000 }),
    );
    await expect(client.fetch('https://example.com/doc')).rejects.toMatchObject({ kind: 'budget' });
    // It fails before sleeping: a caller gains nothing from a wait that was
    // already known to exceed the budget.
    expect(client.slept).toEqual([]);
    expect(client.requested).toHaveLength(1);
  });
});
