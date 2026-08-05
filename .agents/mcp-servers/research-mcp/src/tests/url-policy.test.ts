import { describe, expect, it } from 'vitest';
import { authorizeUrl, isPublicAddress, type Resolver } from '../core/url-policy.js';

const resolvesTo = (...addresses: string[]): Resolver => async () =>
  addresses.map((address) => ({ address, family: address.includes(':') ? 6 : 4 }) as const);

const publicResolver = resolvesTo('93.184.216.34');

describe('authorizeUrl', () => {
  it('allows a public host', async () => {
    const decision = await authorizeUrl('https://example.com/article', publicResolver);
    expect(decision.allowed).toBe(true);
  });

  it.each([
    ['loopback', '127.0.0.1'],
    ['loopback alias', '127.16.9.4'],
    ['private 10/8', '10.1.2.3'],
    ['private 172.16/12', '172.20.0.9'],
    ['private 192.168/16', '192.168.1.1'],
    ['cloud metadata', '169.254.169.254'],
    ['carrier-grade NAT', '100.100.0.1'],
    ['multicast', '224.0.0.1'],
    ['reserved', '240.0.0.1'],
    ['this-network', '0.0.0.0'],
  ])('rejects a host resolving to %s', async (_label, address) => {
    const decision = await authorizeUrl('https://intranet.example/x', resolvesTo(address));
    expect(decision.allowed).toBe(false);
    if (!decision.allowed) expect(decision.reason).toContain(address);
  });

  it.each([
    ['IPv6 loopback', '::1'],
    ['unique local', 'fd00::1'],
    ['link-local', 'fe80::1'],
    ['documentation', '2001:db8::1'],
  ])('rejects a host resolving to %s', async (_label, address) => {
    const decision = await authorizeUrl('https://intranet.example/x', resolvesTo(address));
    expect(decision.allowed).toBe(false);
  });

  it('rejects an IPv4-mapped IPv6 loopback', async () => {
    // A v6-only table would wave ::ffff:127.0.0.1 straight through.
    expect(isPublicAddress({ address: '::ffff:127.0.0.1', family: 6 })).toBe(false);
    expect(isPublicAddress({ address: '::ffff:169.254.169.254', family: 6 })).toBe(false);
    expect(isPublicAddress({ address: '::ffff:93.184.216.34', family: 6 })).toBe(true);
  });

  it('rejects when any address in a multi-record answer is private', async () => {
    const decision = await authorizeUrl(
      'https://split-horizon.example/x',
      resolvesTo('93.184.216.34', '10.0.0.5'),
    );
    expect(decision.allowed).toBe(false);
  });

  it('rejects a literal private address without consulting DNS', async () => {
    const decision = await authorizeUrl('http://169.254.169.254/latest/meta-data/', async () => {
      throw new Error('resolver must not be called for a literal');
    });
    expect(decision.allowed).toBe(false);
  });

  it.each([
    ['file scheme', 'file:///etc/passwd'],
    ['gopher scheme', 'gopher://example.com/'],
    ['embedded credentials', 'https://user:pass@example.com/'],
    ['not a url', 'not a url'],
    ['empty', '   '],
  ])('rejects %s', async (_label, raw) => {
    const decision = await authorizeUrl(raw, publicResolver);
    expect(decision.allowed).toBe(false);
  });

  it('rejects when DNS returns nothing', async () => {
    const decision = await authorizeUrl('https://void.example/', async () => []);
    expect(decision.allowed).toBe(false);
  });

  it('rejects a family mismatch between record and literal', () => {
    expect(isPublicAddress({ address: '93.184.216.34', family: 6 })).toBe(false);
  });

  it('normalises a trailing-dot hostname', async () => {
    const decision = await authorizeUrl('https://example.com./x', publicResolver);
    expect(decision.allowed).toBe(true);
    if (decision.allowed) expect(decision.target.hostname).toBe('example.com');
  });
});
