import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import type { ClientRequestArgs, IncomingMessage } from 'node:http';
import { brotliDecompress, gunzip, inflate } from 'node:zlib';
import { promisify } from 'node:util';
import type { RuntimeConfig } from '../config/env.js';
import { authorizeUrl, type Resolver, type ResolvedAddress, systemResolver } from './url-policy.js';

const gunzipAsync = promisify(gunzip);
const inflateAsync = promisify(inflate);
const brotliAsync = promisify(brotliDecompress);

export interface FetchResult {
  url: string;
  status: number;
  contentType: string;
  /** Decoded text. Empty for binary payloads — read `bytes` instead. */
  text: string;
  bytes: Buffer;
  /** True when the body hit the size cap and the payload is incomplete. */
  truncated: boolean;
  redirects: readonly string[];
}

/** The narrow contract collaborators depend on, so they can be tested without a socket. */
export interface Fetcher {
  fetch(url: string, options?: { accept?: string; intervalMs?: number }): Promise<FetchResult>;
}

export class FetchError extends Error {
  constructor(
    message: string,
    readonly kind: 'policy' | 'network' | 'http' | 'size',
    /** Present for `kind: 'http'`, so callers can branch on the code itself. */
    readonly status?: number,
  ) {
    super(message);
    this.name = 'FetchError';
  }
}

/**
 * Whether another attempt could plausibly succeed. A 429 or a 5xx is the server
 * reporting a condition of its own; every other 4xx is the server rejecting
 * this request, and repeating it only burns the host's rate budget.
 */
export function isRetryableStatus(status: number): boolean {
  return status === 429 || (status >= 500 && status < 600);
}

/**
 * Milliseconds from a `Retry-After` header in either permitted form, a delta in
 * seconds or an HTTP date. Returns null when absent or unparseable.
 */
export function parseRetryAfterMs(raw: string | undefined, now = Date.now()): number | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed) * 1_000;
  const at = Date.parse(trimmed);
  if (Number.isNaN(at)) return null;
  return Math.max(0, at - now);
}

const JITTER_MS = 250;

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms).unref?.();
  });

/**
 * Serialises requests per host. Crossref, arXiv and Unpaywall each publish a
 * rate they expect callers to hold to, and a research fetch is never so urgent
 * that it justifies ignoring them.
 */
class HostRateLimiter {
  private readonly tails = new Map<string, Promise<void>>();

  constructor(private readonly defaultIntervalMs: number) {}

  async acquire(host: string, intervalMs = this.defaultIntervalMs): Promise<void> {
    if (intervalMs <= 0) return;
    const previous = this.tails.get(host) ?? Promise.resolve();
    let release: () => void = () => {};
    const next = new Promise<void>((resolve) => {
      release = resolve;
    });
    this.tails.set(host, previous.then(() => next));
    await previous;
    setTimeout(release, intervalMs).unref?.();
  }
}

export class HttpClient implements Fetcher {
  private readonly limiter: HostRateLimiter;

  constructor(
    private readonly config: RuntimeConfig,
    private readonly resolver: Resolver = systemResolver,
  ) {
    this.limiter = new HostRateLimiter(config.minHostIntervalMs);
  }

  /**
   * Fetches a URL, re-running the address policy on every redirect hop and
   * connecting only to addresses that policy already cleared.
   */
  async fetch(
    rawUrl: string,
    options: { accept?: string; intervalMs?: number } = {},
  ): Promise<FetchResult> {
    const redirects: string[] = [];
    let current = rawUrl;

    for (let hop = 0; hop <= this.config.maxRedirects; hop += 1) {
      // Re-authorised per hop: a public first response may redirect to
      // 169.254.169.254, and a short-TTL name may resolve differently now.
      const decision = await authorizeUrl(current, this.resolver);
      if (!decision.allowed) throw new FetchError(decision.reason, 'policy');
      const { url, hostname, addresses } = decision.target;

      const response = await this.sendWithRetry(url, hostname, addresses, options);

      const location = response.headers.location;
      const status = response.statusCode ?? 0;
      if (status >= 300 && status < 400 && location) {
        response.resume();
        if (hop === this.config.maxRedirects) {
          throw new FetchError(`Exceeded ${this.config.maxRedirects} redirects`, 'http');
        }
        redirects.push(url.toString());
        current = new URL(location, url).toString();
        continue;
      }

      const { bytes, truncated } = await this.readBody(response);
      if (status >= 400) {
        throw new FetchError(`HTTP ${status} from ${url.hostname}`, 'http', status);
      }
      const contentType = response.headers['content-type'] ?? '';
      return {
        url: url.toString(),
        status,
        contentType,
        text: isBinary(contentType) ? '' : decode(bytes, contentType),
        bytes,
        truncated,
        redirects,
      };
    }
    throw new FetchError('Redirect loop', 'http');
  }

  /**
   * One redirect hop, retried on conditions the origin reports as its own.
   *
   * Retrying here rather than around the whole fetch keeps every attempt inside
   * the hop the address policy just cleared: re-entering the outer loop would
   * replay earlier hops, and re-running a redirect chain to recover from a 503
   * multiplies the requests the origin sees.
   *
   * Hands back the response untouched once attempts run out, so a caller that
   * treats an exhausted 503 as an ordinary error needs no special case.
   */
  private async sendWithRetry(
    url: URL,
    hostname: string,
    addresses: readonly ResolvedAddress[],
    options: { accept?: string; intervalMs?: number },
  ): Promise<IncomingMessage> {
    for (let attempt = 0; ; attempt += 1) {
      const last = attempt >= this.config.retries;
      await this.limiter.acquire(hostname, options.intervalMs);

      let response: IncomingMessage;
      try {
        response = await this.send(url, addresses, options.accept);
      } catch (error) {
        // A timeout, a reset or a DNS failure carries no status and may well be
        // transient. A policy refusal is a decision and never retried.
        const transient = error instanceof FetchError && error.kind === 'network';
        if (last || !transient) throw error;
        await sleep(this.backoffMs(attempt));
        continue;
      }

      const status = response.statusCode ?? 0;
      if (last || !isRetryableStatus(status)) return response;

      // The body of a 503 is a courtesy page. Draining frees the socket for the
      // next attempt instead of leaving it half-read.
      const retryAfter = parseRetryAfterMs(response.headers['retry-after']);
      response.resume();
      await sleep(retryAfter === null ? this.backoffMs(attempt) : this.clampRetryAfter(retryAfter));
    }
  }

  /** Exponential backoff under the configured ceiling, plus jitter. */
  private backoffMs(attempt: number): number {
    // The jitter is reserved out of the ceiling rather than added on top, so the
    // total still honours the configured maximum. It matters most exactly where
    // the curve has flattened and every caller would otherwise wake together.
    const jitter = Math.min(JITTER_MS, Math.max(0, this.config.retryMaxDelayMs));
    const ceiling = Math.max(0, this.config.retryMaxDelayMs - jitter);
    return Math.min(this.config.retryBaseDelayMs * 2 ** attempt, ceiling) + Math.random() * jitter;
  }

  /**
   * Honours the origin's own pacing, but only so far. `Retry-After: 86400` is
   * either hostile or misconfigured, and either way a research read must not
   * park a process for a day.
   */
  private clampRetryAfter(ms: number): number {
    return Math.min(ms, this.config.retryMaxDelayMs * 4);
  }

  /**
   * The single socket-touching call. `protected` so a test can drive the retry
   * loop without a live origin: the address policy rejects loopback by design,
   * so there is no local server this class would ever agree to talk to.
   */
  protected send(
    url: URL,
    addresses: readonly ResolvedAddress[],
    accept?: string,
  ): Promise<IncomingMessage> {
    const secure = url.protocol === 'https:';
    const options: ClientRequestArgs = {
      method: 'GET',
      protocol: url.protocol,
      hostname: url.hostname,
      port: url.port || (secure ? 443 : 80),
      path: `${url.pathname}${url.search}`,
      headers: {
        'user-agent': this.config.userAgent,
        accept: accept ?? 'text/html,application/xhtml+xml,application/pdf;q=0.9,*/*;q=0.8',
        'accept-encoding': 'gzip, deflate, br',
        'accept-language': 'en',
      },
      timeout: this.config.requestTimeoutMs,
      // Pinned to the addresses the policy validated, closing the window
      // between resolving a name and connecting to it.
      lookup: pinnedLookup(addresses),
      // A pooled socket could outlive its pin and be reused for another name.
      agent: false,
    };
    return new Promise((resolve, reject) => {
      const call = secure ? httpsRequest : httpRequest;
      const req = call(options, resolve);
      req.on('timeout', () => {
        req.destroy(new FetchError(`Timed out after ${this.config.requestTimeoutMs}ms`, 'network'));
      });
      req.on('error', (error: Error) =>
        reject(error instanceof FetchError ? error : new FetchError(error.message, 'network')),
      );
      req.end();
    });
  }

  private async readBody(response: IncomingMessage): Promise<{ bytes: Buffer; truncated: boolean }> {
    const chunks: Buffer[] = [];
    let size = 0;
    let truncated = false;
    await new Promise<void>((resolve, reject) => {
      response.on('data', (chunk: Buffer) => {
        size += chunk.length;
        if (size > this.config.maxBodyBytes) {
          truncated = true;
          response.destroy();
          resolve();
          return;
        }
        chunks.push(chunk);
      });
      response.on('end', resolve);
      response.on('error', (error: Error) => reject(new FetchError(error.message, 'network')));
    });

    const raw = Buffer.concat(chunks);
    const encoding = String(response.headers['content-encoding'] ?? '').toLowerCase();
    if (!encoding || encoding === 'identity') return { bytes: raw, truncated };
    if (truncated) {
      // A compressed stream cut mid-frame cannot be inflated at all, so there
      // is no partial result to hand back.
      throw new FetchError(
        `Response exceeded ${this.config.maxBodyBytes} bytes and is compressed; no partial body is recoverable`,
        'size',
      );
    }
    return { bytes: await decompress(raw, encoding, this.config.maxBodyBytes), truncated };
  }
}

/**
 * Inflates a response body under a hard output ceiling.
 *
 * The transport's byte cap counts the *compressed* stream, which bounds nothing:
 * 200 KB of gzip expands to 200 MB. `maxOutputLength` makes zlib abort instead
 * of allocating, so a compression bomb costs one rejected request rather than
 * the process.
 */
export async function decompress(
  raw: Buffer,
  encoding: string,
  maxBytes: number,
): Promise<Buffer> {
  const normalized = encoding.trim().toLowerCase();
  if (!normalized || normalized === 'identity') return raw;
  const limit = { maxOutputLength: maxBytes };
  try {
    if (normalized === 'gzip') return await gunzipAsync(raw, limit);
    if (normalized === 'deflate') return await inflateAsync(raw, limit);
    if (normalized === 'br') return await brotliAsync(raw, limit);
  } catch (error) {
    const failure = error as NodeJS.ErrnoException;
    if (failure.code === 'ERR_BUFFER_TOO_LARGE') {
      throw new FetchError(`Decompressed ${normalized} body exceeds ${maxBytes} bytes`, 'size');
    }
    throw new FetchError(
      `Failed to decompress ${normalized} response: ${failure.message}`,
      'network',
    );
  }
  // An encoding nothing here implements: hand back the raw bytes rather than
  // pretending they decoded.
  return raw;
}

function pinnedLookup(addresses: readonly ResolvedAddress[]): ClientRequestArgs['lookup'] {
  return ((hostname, options, callback) => {
    const entries = addresses.map((entry) => ({ address: entry.address, family: entry.family }));
    if (typeof options === 'object' && options?.all) {
      (callback as (e: null, a: typeof entries) => void)(null, entries);
      return;
    }
    const first = entries[0];
    if (!first) {
      (callback as (e: Error) => void)(new Error('no pinned address'));
      return;
    }
    (callback as (e: null, a: string, f: number) => void)(null, first.address, first.family);
  }) as ClientRequestArgs['lookup'];
}

const BINARY = /^(application\/pdf|image\/|audio\/|video\/|application\/octet-stream|application\/zip)/i;
export function isBinary(contentType: string): boolean {
  return BINARY.test(contentType.trim());
}

/**
 * Decodes to text using the charset the server declared, falling back to the
 * document's own `<meta charset>`. Assuming UTF-8 mojibakes every legacy page,
 * which on the public web is a daily occurrence rather than an edge case.
 */
export function decode(bytes: Buffer, contentType: string): string {
  const declared = /charset=["']?([\w-]+)/i.exec(contentType)?.[1];
  const sniffed = declared
    ? undefined
    : /<meta[^>]+charset=["']?([\w-]+)/i.exec(bytes.subarray(0, 4096).toString('latin1'))?.[1];
  const charset = (declared ?? sniffed ?? 'utf-8').toLowerCase();
  try {
    return new TextDecoder(charset, { fatal: false }).decode(bytes);
  } catch {
    return new TextDecoder('utf-8', { fatal: false }).decode(bytes);
  }
}
