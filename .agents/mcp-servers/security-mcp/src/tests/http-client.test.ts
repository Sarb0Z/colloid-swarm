import { describe, expect, it } from 'vitest';
import type { RuntimeConfig } from '../config/env.js';
import {
  authorizedRequest,
  RequestBudget,
  type NetworkTransport,
} from '../core/scanner/http-client.js';
import type { Resolver } from '../core/policy/target-policy.js';
import { SecretRedactor } from '../core/policy/redaction.js';

const config: RuntimeConfig = {
  allowedHosts: new Set(['stage.example.test']),
  requestTimeoutMs: 1_000,
  maxRequests: 4,
  maxDepth: 1,
  maxRedirects: 2,
  maxBodyBytes: 16_384,
};
const publicResolver: Resolver = async () => [{ address: '93.184.216.34', family: 4 }];

describe('authorized request', () => {
  it('normalizes only percent-triplet case while preserving raw secret case', () => {
    const redactor = SecretRedactor.fromCredentials({ bearerToken: 'Case/Secret?' });
    expect(redactor.scrub('case/secret?')).toBe('case/secret?');
    expect(redactor.scrub('Case%2fSecret%3f')).toBe('[REDACTED]');
  });

  it('does not call the transport for a rejected target', async () => {
    let calls = 0;
    const transport: NetworkTransport = async () => {
      calls += 1;
      throw new Error('must not run');
    };
    await expect(
      authorizedRequest(
        'https://unconfigured.example.test',
        undefined,
        config,
        new RequestBudget(4),
        { resolver: publicResolver, transport },
      ),
    ).rejects.toThrow('not in SECURITY_MCP_ALLOWED_HOSTS');
    expect(calls).toBe(0);
  });

  it('blocks a redirect before sending a request to its destination', async () => {
    let calls = 0;
    const transport: NetworkTransport = async () => {
      calls += 1;
      return {
        status: 302,
        headers: { location: 'http://169.254.169.254/latest/meta-data' },
        body: '',
        bytes: 0,
      };
    };
    await expect(
      authorizedRequest(
        'https://stage.example.test',
        undefined,
        config,
        new RequestBudget(4),
        { resolver: publicResolver, transport },
      ),
    ).rejects.toThrow('Request refused');
    expect(calls).toBe(1);
  });

  it('pins the resolved address passed to the transport', async () => {
    let resolutions = 0;
    const resolver: Resolver = async () => {
      resolutions += 1;
      return [{ address: resolutions === 1 ? '93.184.216.34' : '127.0.0.1', family: 4 }];
    };
    const transport: NetworkTransport = async (target) => {
      expect(target.addresses).toEqual([{ address: '93.184.216.34', family: 4 }]);
      return { status: 200, headers: {}, body: '', bytes: 0 };
    };
    await authorizedRequest(
      'https://stage.example.test',
      undefined,
      config,
      new RequestBudget(4),
      { resolver, transport },
    );
    expect(resolutions).toBe(1);
  });

  it('redacts request URL secrets and response cookie values', async () => {
    const token = 'token/value +never-return';
    const cookie = 'cookie?value=&never-return';
    const encodedToken = encodeURIComponent(token);
    const encodedCookie = encodeURIComponent(cookie);
    const transport: NetworkTransport = async (_target, headers) => {
      expect(headers.authorization).toBe(`Bearer ${token}`);
      expect(headers.cookie).toBe(`session=${cookie}`);
      return {
        status: 200,
        headers: {
          'set-cookie': `session=${cookie}; HttpOnly; Secure`,
          server: `reflected-${encodedToken}`,
          'x-powered-by': `reflected-${cookie}`,
        },
        body: `<a href="/next?trace=${encodedCookie}">${token}</a>`,
        bytes: 80,
      };
    };
    const outcome = await authorizedRequest(
      `https://stage.example.test/?refresh_token=${token}&client-secret=${cookie}`,
      { bearerToken: token, cookies: { session: cookie } },
      config,
      new RequestBudget(4),
      { resolver: publicResolver, transport },
    );
    const serialized = JSON.stringify(outcome);
    expect(serialized).not.toContain(token);
    expect(serialized).not.toContain(cookie);
    expect(serialized).not.toContain(encodedToken);
    expect(serialized).not.toContain(encodedCookie);
    expect(outcome.setCookies[0]).toContain('[REDACTED]');
  });

  it('redacts credential values from transport errors', async () => {
    const token = 'error/token value';
    const encoded = encodeURIComponent(token);
    const transport: NetworkTransport = async () => {
      throw new Error(`upstream reflected ${token} and ${encoded}`);
    };
    await expect(
      authorizedRequest(
        'https://stage.example.test',
        { bearerToken: token },
        config,
        new RequestBudget(4),
        { resolver: publicResolver, transport },
      ),
    ).rejects.not.toThrow(token);
    await expect(
      authorizedRequest(
        'https://stage.example.test',
        { bearerToken: token },
        config,
        new RequestBudget(4),
        { resolver: publicResolver, transport },
      ),
    ).rejects.not.toThrow(encoded);
  });
});
