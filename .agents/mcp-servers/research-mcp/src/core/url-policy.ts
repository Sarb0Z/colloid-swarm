import { lookup } from 'node:dns/promises';
import { BlockList, isIP } from 'node:net';

// This server is handed URLs by pages it does not control, and follows their
// redirects. The guard is therefore the inverse of a scanner's: every address a
// hostname resolves to must be public, and the verdict must be recomputed on
// every hop rather than once at entry.
//
// debt: research-01-duplicate-ssrf-tables

const blockedV4 = new BlockList();
for (const [network, prefix] of [
  ['0.0.0.0', 8],          // this-network
  ['10.0.0.0', 8],         // private
  ['100.64.0.0', 10],      // carrier-grade NAT
  ['127.0.0.0', 8],        // loopback
  ['169.254.0.0', 16],     // link-local, incl. cloud metadata at 169.254.169.254
  ['172.16.0.0', 12],      // private
  ['192.0.0.0', 24],       // IETF protocol assignments
  ['192.0.2.0', 24],       // TEST-NET-1
  ['192.88.99.0', 24],     // 6to4 relay anycast
  ['192.168.0.0', 16],     // private
  ['198.18.0.0', 15],      // benchmarking
  ['198.51.100.0', 24],    // TEST-NET-2
  ['203.0.113.0', 24],     // TEST-NET-3
  ['224.0.0.0', 4],        // multicast
  ['240.0.0.0', 4],        // reserved, incl. broadcast
] as const) {
  blockedV4.addSubnet(network, prefix, 'ipv4');
}

const blockedV6 = new BlockList();
for (const [network, prefix] of [
  ['::', 128],             // unspecified
  ['::1', 128],            // loopback
  ['::ffff:0:0', 96],      // IPv4-mapped — must be rejected, then re-checked as v4
  ['64:ff9b::', 96],       // NAT64
  ['64:ff9b:1::', 48],     // local-use NAT64
  ['100::', 64],           // discard-only
  ['2001::', 32],          // Teredo
  ['2001:2::', 48],        // benchmarking
  ['2001:10::', 28],       // ORCHID
  ['2001:20::', 28],       // ORCHIDv2
  ['2001:db8::', 32],      // documentation
  ['2002::', 16],          // 6to4
  ['fc00::', 7],           // unique local
  ['fe80::', 10],          // link-local
  ['ff00::', 8],           // multicast
] as const) {
  blockedV6.addSubnet(network, prefix, 'ipv6');
}

export interface ResolvedAddress {
  address: string;
  family: 4 | 6;
}

export type Resolver = (hostname: string) => Promise<readonly ResolvedAddress[]>;

export interface AllowedTarget {
  url: URL;
  hostname: string;
  /** Every address the guard validated. The transport must connect only to these. */
  addresses: readonly ResolvedAddress[];
}

export type PolicyDecision =
  | { allowed: true; target: AllowedTarget }
  | { allowed: false; reason: string };

export const systemResolver: Resolver = async (hostname) => {
  const records = await lookup(hostname, { all: true, verbatim: true });
  return records.map(({ address, family }) => ({ address, family: family === 6 ? 6 : 4 }));
};

export function isPublicAddress(entry: ResolvedAddress): boolean {
  const actual = isIP(entry.address);
  if (actual !== entry.family) return false;
  if (entry.family === 4) return !blockedV4.check(entry.address, 'ipv4');
  // An IPv4-mapped IPv6 literal must be judged by its embedded v4 address, or
  // ::ffff:127.0.0.1 walks straight past a v6-only table.
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(entry.address);
  if (mapped?.[1]) return !blockedV4.check(mapped[1], 'ipv4');
  return !blockedV6.check(entry.address, 'ipv6');
}

export async function authorizeUrl(
  rawUrl: string,
  resolver: Resolver = systemResolver,
): Promise<PolicyDecision> {
  const parsed = parseUrl(rawUrl);
  if ('reason' in parsed) return { allowed: false, reason: parsed.reason };
  const { url, hostname } = parsed;

  let addresses: readonly ResolvedAddress[];
  const literal = isIP(hostname);
  if (literal) {
    addresses = [{ address: hostname, family: literal as 4 | 6 }];
  } else {
    try {
      addresses = await resolver(hostname);
    } catch {
      return { allowed: false, reason: `DNS resolution failed for ${hostname}` };
    }
  }
  if (addresses.length === 0) {
    return { allowed: false, reason: `DNS returned no addresses for ${hostname}` };
  }
  const rejected = addresses.find((entry) => !isPublicAddress(entry));
  if (rejected) {
    return {
      allowed: false,
      reason: `${hostname} resolves to non-public address ${rejected.address}`,
    };
  }
  return { allowed: true, target: { url, hostname, addresses } };
}

function parseUrl(rawUrl: string): { url: URL; hostname: string } | { reason: string } {
  const trimmed = rawUrl.trim();
  if (!trimmed) return { reason: 'url is empty' };
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return { reason: 'url is not a valid URL' };
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    return { reason: `Only HTTP and HTTPS are supported, got ${url.protocol}` };
  }
  if (url.username || url.password) {
    return { reason: 'Credentials are not permitted in the URL' };
  }
  const hostname = url.hostname.toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');
  if (!hostname) return { reason: 'URL has no hostname' };
  return { url, hostname };
}
