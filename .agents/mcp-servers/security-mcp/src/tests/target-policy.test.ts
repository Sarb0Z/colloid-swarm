import { describe, expect, it } from 'vitest';
import type { RuntimeConfig } from '../config/env.js';
import { authorizeTarget, type Resolver } from '../core/policy/target-policy.js';

const config = (allowedHosts: string[] = []): RuntimeConfig => ({
  allowedHosts: new Set(allowedHosts),
  requestTimeoutMs: 1_000,
  maxRequests: 10,
  maxDepth: 2,
  maxRedirects: 2,
  maxBodyBytes: 16_384,
});

describe('target authorization', () => {
  it('rejects an unconfigured host before DNS resolution', async () => {
    let resolutions = 0;
    const resolver: Resolver = async () => {
      resolutions += 1;
      return [{ address: '93.184.216.34', family: 4 }];
    };
    const result = await authorizeTarget('https://example.com', config(), resolver);
    expect(result.allowed).toBe(false);
    expect(resolutions).toBe(0);
  });

  it('allows only exact configured hosts over HTTPS', async () => {
    const resolver: Resolver = async () => [{ address: '93.184.216.34', family: 4 }];
    await expect(
      authorizeTarget('https://stage.example.test', config(['stage.example.test']), resolver),
    ).resolves.toMatchObject({ allowed: true, classification: 'staging' });
    await expect(
      authorizeTarget('https://child.stage.example.test', config(['stage.example.test']), resolver),
    ).resolves.toMatchObject({ allowed: false });
    await expect(
      authorizeTarget('http://stage.example.test', config(['stage.example.test']), resolver),
    ).resolves.toMatchObject({ allowed: false, reason: 'Configured staging hosts require HTTPS' });
  });

  it.each(['prod.example.test', 'api-production.example.test', 'live.example.test'])(
    'rejects production-like configured hostname %s before DNS',
    async (hostname) => {
      let resolutions = 0;
      const resolver: Resolver = async () => {
        resolutions += 1;
        return [{ address: '93.184.216.34', family: 4 }];
      };
      const result = await authorizeTarget(`https://${hostname}`, config([hostname]), resolver);
      expect(result.allowed).toBe(false);
      expect(resolutions).toBe(0);
    },
  );

  it.each([
    ['10.0.0.1', 4],
    ['169.254.169.254', 4],
    ['224.0.0.1', 4],
    ['192.0.2.1', 4],
    ['fc00::1', 6],
    ['fe80::1', 6],
    ['ff02::1', 6],
    ['2001:db8::1', 6],
    ['64:ff9b::c000:201', 6],
    ['2002:c000:0201::1', 6],
  ] as const)('rejects configured host resolving to blocked address %s', async (address, family) => {
    const resolver: Resolver = async () => [{ address, family }];
    const result = await authorizeTarget(
      'https://stage.example.test',
      config(['stage.example.test']),
      resolver,
    );
    expect(result.allowed).toBe(false);
  });

  it('requires localhost DNS to resolve only to loopback', async () => {
    const rebound: Resolver = async () => [{ address: '93.184.216.34', family: 4 }];
    await expect(authorizeTarget('http://localhost:3000', config(), rebound)).resolves.toMatchObject({
      allowed: false,
    });
    const local: Resolver = async () => [
      { address: '127.0.0.1', family: 4 },
      { address: '::1', family: 6 },
    ];
    await expect(authorizeTarget('http://localhost:3000', config(), local)).resolves.toMatchObject({
      allowed: true,
      classification: 'loopback',
    });
  });

  it('rejects a configured host when any DNS answer is blocked', async () => {
    const mixed: Resolver = async () => [
      { address: '93.184.216.34', family: 4 },
      { address: '127.0.0.1', family: 4 },
    ];
    await expect(
      authorizeTarget('https://stage.example.test', config(['stage.example.test']), mixed),
    ).resolves.toMatchObject({ allowed: false });
  });
});
