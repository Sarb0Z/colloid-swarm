import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import type { LookupFunction } from 'node:net';
import type { RuntimeConfig } from '../../config/env.js';
import {
  authorizeTarget,
  type AuthorizedTarget,
  type Resolver,
  systemResolver,
} from '../policy/target-policy.js';
import { SecretRedactor, sanitizeSetCookies } from '../policy/redaction.js';

export interface RequestCredentials {
  bearerToken?: string;
  cookies?: Readonly<Record<string, string>>;
}

export interface RequestOutcome {
  requestedUrl: string;
  finalUrl: string;
  status: number;
  headers: Record<string, string>;
  setCookies: string[];
  body: string;
  bytes: number;
  redirects: number;
  truncated: boolean;
  bodyLimitBytes: number;
}

interface RawOutcome {
  status: number;
  headers: Record<string, string | string[] | undefined>;
  body: string;
  bytes: number;
  truncated?: boolean;
}

export type NetworkTransport = (
  target: AuthorizedTarget,
  headers: Readonly<Record<string, string>>,
  config: RuntimeConfig,
) => Promise<RawOutcome>;

export class RequestBudget {
  private usedCount = 0;

  constructor(
    private readonly maximum: number,
    private readonly parent?: RequestBudget,
  ) {}

  take(): void {
    if (this.usedCount >= this.maximum) throw new Error('Request limit reached');
    this.parent?.take();
    this.usedCount += 1;
  }

  get used(): number {
    return this.usedCount;
  }

  get remaining(): number {
    return this.maximum - this.usedCount;
  }
}

export interface AuthorizedRequestDependencies {
  resolver?: Resolver;
  transport?: NetworkTransport;
}

export async function authorizedRequest(
  rawUrl: string,
  credentials: RequestCredentials | undefined,
  config: RuntimeConfig,
  budget: RequestBudget,
  dependencies: AuthorizedRequestDependencies = {},
): Promise<RequestOutcome> {
  const resolver = dependencies.resolver ?? systemResolver;
  const transport = dependencies.transport ?? nodeTransport;
  const redactor = SecretRedactor.fromCredentials(credentials);
  const requestedUrl = redactor.scrubUrl(rawUrl);
  let current = rawUrl;
  let redirects = 0;
  let credentialsAllowedForOrigin: string | undefined;

  try {
    credentialsAllowedForOrigin = new URL(rawUrl).origin;
  } catch {
    // Authorization below returns the stable validation error.
  }

  for (;;) {
    const decision = await authorizeTarget(current, config, resolver);
    if (!decision.allowed || !decision.target) {
      throw new Error(`Request refused: ${decision.reason}`);
    }
    budget.take();
    const headers = requestHeaders(
      decision.target.url.origin === credentialsAllowedForOrigin ? credentials : undefined,
    );
    let raw: RawOutcome;
    try {
      raw = await transport(decision.target, headers, config);
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Network request failed';
      throw new Error(redactor.scrub(message));
    }
    const location = firstHeader(raw.headers.location);
    if (!isRedirect(raw.status) || !location) {
      return {
        requestedUrl,
        finalUrl: redactor.scrubUrl(decision.target.url.toString()),
        status: raw.status,
        headers: safeResponseHeaders(raw.headers, redactor),
        setCookies: sanitizeSetCookies(headerValues(raw.headers['set-cookie'])).map((value) =>
          redactor.scrub(value),
        ),
        body: redactor.scrub(raw.body),
        bytes: raw.bytes,
        redirects,
        truncated: raw.truncated ?? false,
        bodyLimitBytes: config.maxBodyBytes,
      };
    }
    if (redirects >= config.maxRedirects) throw new Error('Redirect limit reached');
    current = new URL(location, decision.target.url).toString();
    redirects += 1;
  }
}

const nodeTransport: NetworkTransport = async (target, headers, config) => {
  const pinned = target.addresses;
  const lookupPinned: LookupFunction = (_hostname, options, callback) => {
    const requestedFamily =
      typeof options === 'number'
        ? options
        : options.family === 'IPv4'
          ? 4
          : options.family === 'IPv6'
            ? 6
            : options.family;
    const eligible = pinned.filter((entry) => !requestedFamily || entry.family === requestedFamily);
    if (typeof options !== 'number' && options.all) {
      if (eligible.length === 0) {
        callback(new Error('No pinned address is available'), []);
        return;
      }
      callback(null, eligible.map(({ address, family }) => ({ address, family })));
      return;
    }
    const selected =
      eligible[0] ?? pinned[0];
    if (!selected) {
      callback(new Error('No pinned address is available'), '', 4);
      return;
    }
    callback(null, selected.address, selected.family);
  };
  const issue = target.url.protocol === 'https:' ? httpsRequest : httpRequest;

  return await new Promise<RawOutcome>((resolve, reject) => {
    const request = issue(
      target.url,
      {
        method: 'GET',
        headers,
        lookup: lookupPinned,
        agent: false,
        signal: AbortSignal.timeout(config.requestTimeoutMs),
      },
      (response) => {
        const chunks: Buffer[] = [];
        let bytes = 0;
        let retainedBytes = 0;
        let settled = false;
        const finish = (truncated: boolean) => {
          if (settled) return;
          settled = true;
          resolve({
            status: response.statusCode ?? 0,
            headers: response.headers,
            body: Buffer.concat(chunks).toString('utf8'),
            bytes,
            truncated,
          });
          if (truncated) response.destroy();
        };
        response.on('data', (chunk: Buffer) => {
          const remaining = config.maxBodyBytes - retainedBytes;
          if (chunk.length > remaining) {
            const retained = chunk.subarray(0, remaining);
            chunks.push(retained);
            retainedBytes += retained.length;
            bytes = retainedBytes;
            finish(true);
            return;
          }
          chunks.push(chunk);
          retainedBytes += chunk.length;
          bytes = retainedBytes;
        });
        response.on('end', () => finish(false));
        response.on('aborted', () => {
          if (!settled) reject(new Error('Network response ended before completion'));
        });
        response.on('error', (error: NodeJS.ErrnoException) => {
          if (settled) return;
          const code = typeof error.code === 'string' ? error.code : 'NETWORK_ERROR';
          reject(new Error(`Network response failed (${code})`));
        });
      },
    );
    request.on('error', (error: NodeJS.ErrnoException) => {
      const code = typeof error.code === 'string' ? error.code : 'NETWORK_ERROR';
      reject(new Error(`Network request failed (${code})`));
    });
    request.end();
  });
};

function requestHeaders(credentials: RequestCredentials | undefined): Record<string, string> {
  const headers: Record<string, string> = {
    accept: 'application/json, text/html;q=0.9, */*;q=0.5',
    'user-agent': 'security-mcp/0.10.0-colloid (+authorized-testing-only)',
  };
  if (credentials?.bearerToken) headers.authorization = `Bearer ${credentials.bearerToken}`;
  if (credentials?.cookies && Object.keys(credentials.cookies).length > 0) {
    headers.cookie = Object.entries(credentials.cookies)
      .map(([name, value]) => `${name}=${value}`)
      .join('; ');
  }
  return headers;
}

function safeResponseHeaders(
  headers: Record<string, string | string[] | undefined>,
  redactor: SecretRedactor,
): Record<string, string> {
  const safe = new Set([
    'access-control-allow-credentials',
    'access-control-allow-origin',
    'cache-control',
    'content-security-policy',
    'content-type',
    'cross-origin-opener-policy',
    'cross-origin-resource-policy',
    'permissions-policy',
    'referrer-policy',
    'server',
    'strict-transport-security',
    'vary',
    'x-content-type-options',
    'x-debug-mode',
    'x-frame-options',
    'x-powered-by',
  ]);
  const result: Record<string, string> = {};
  for (const [name, value] of Object.entries(headers)) {
    if (!safe.has(name.toLowerCase()) || value === undefined) continue;
    result[name.toLowerCase()] = redactor.scrub(Array.isArray(value) ? value.join(', ') : value);
  }
  return result;
}

function firstHeader(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

function headerValues(value: string | string[] | undefined): string[] {
  if (value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

function isRedirect(status: number): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308;
}
