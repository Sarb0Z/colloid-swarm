import { lookup } from 'node:dns/promises';
import { BlockList, isIP } from 'node:net';
import type { RuntimeConfig } from '../../config/env.js';

export interface ResolvedAddress {
  address: string;
  family: 4 | 6;
}

export type Resolver = (hostname: string) => Promise<readonly ResolvedAddress[]>;

export interface AuthorizedTarget {
  url: URL;
  hostname: string;
  classification: 'loopback' | 'staging';
  addresses: readonly ResolvedAddress[];
}

export interface TargetDecision {
  allowed: boolean;
  reason: string;
  normalizedUrl?: string;
  classification?: AuthorizedTarget['classification'];
  target?: AuthorizedTarget;
}

const blockedV4 = new BlockList();
for (const [network, prefix] of [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.0.2.0', 24],
  ['192.88.99.0', 24],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['198.51.100.0', 24],
  ['203.0.113.0', 24],
  ['224.0.0.0', 4],
  ['240.0.0.0', 4],
] as const) {
  blockedV4.addSubnet(network, prefix, 'ipv4');
}

const blockedV6 = new BlockList();
for (const [network, prefix] of [
  ['::', 128],
  ['::1', 128],
  ['::ffff:0:0', 96],
  ['64:ff9b::', 96],
  ['64:ff9b:1::', 48],
  ['100::', 64],
  ['2001::', 32],
  ['2001:2::', 48],
  ['2001:10::', 28],
  ['2001:20::', 28],
  ['2001:db8::', 32],
  ['2002::', 16],
  ['fc00::', 7],
  ['fe80::', 10],
  ['ff00::', 8],
] as const) {
  blockedV6.addSubnet(network, prefix, 'ipv6');
}

const productionMarker = /(^|[.-])(prod|production|live)([.-]|$)/i;

export const systemResolver: Resolver = async (hostname) => {
  const records = await lookup(hostname, { all: true, verbatim: true });
  return records.map(({ address, family }) => ({ address, family: family === 6 ? 6 : 4 }));
};

export async function authorizeTarget(
  rawUrl: string,
  config: RuntimeConfig,
  resolver: Resolver = systemResolver,
): Promise<TargetDecision> {
  const parsed = parseTarget(rawUrl);
  if ('reason' in parsed) return { allowed: false, reason: parsed.reason };

  const { url, hostname } = parsed;
  const loopbackLiteral = isLoopbackLiteral(hostname);
  const localhostName = hostname === 'localhost';
  const classification = loopbackLiteral || localhostName ? 'loopback' : 'staging';

  if (productionMarker.test(hostname)) {
    return { allowed: false, reason: `Hostname ${hostname} is production-like` };
  }
  if (classification === 'staging' && !config.allowedHosts.has(hostname)) {
    return { allowed: false, reason: `Host ${hostname} is not in SECURITY_MCP_ALLOWED_HOSTS` };
  }
  if (classification === 'staging' && url.protocol !== 'https:') {
    return { allowed: false, reason: 'Configured staging hosts require HTTPS' };
  }

  let addresses: readonly ResolvedAddress[];
  if (isIP(hostname)) {
    addresses = [{ address: hostname, family: isIP(hostname) as 4 | 6 }];
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
  if (addresses.some((entry) => !addressAllowed(entry, classification))) {
    return {
      allowed: false,
      reason:
        classification === 'loopback'
          ? `${hostname} did not resolve only to loopback addresses`
          : `${hostname} resolved to a private, reserved, metadata, or multicast address`,
    };
  }

  const target: AuthorizedTarget = { url, hostname, classification, addresses };
  return {
    allowed: true,
    reason: classification === 'loopback' ? 'Loopback target' : 'Exact configured staging host',
    normalizedUrl: url.toString(),
    classification,
    target,
  };
}

function parseTarget(rawUrl: string): { url: URL; hostname: string } | { reason: string } {
  const trimmed = rawUrl.trim();
  if (!trimmed) return { reason: 'targetUrl is empty' };
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return { reason: 'targetUrl is not a valid URL' };
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    return { reason: 'Only HTTP and HTTPS targets are permitted' };
  }
  if (url.username || url.password) {
    return { reason: 'Credentials are not permitted in target URLs' };
  }
  const hostname = url.hostname.toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');
  if (!hostname) return { reason: 'Target URL has no hostname' };
  return { url, hostname };
}

function isLoopbackLiteral(hostname: string): boolean {
  if (hostname === '::1') return true;
  if (isIP(hostname) !== 4) return false;
  return hostname.split('.')[0] === '127';
}

function addressAllowed(
  entry: ResolvedAddress,
  classification: AuthorizedTarget['classification'],
): boolean {
  if (isIP(entry.address) !== entry.family) return false;
  if (classification === 'loopback') return isLoopbackLiteral(entry.address);
  return entry.family === 4
    ? !blockedV4.check(entry.address, 'ipv4')
    : !blockedV6.check(entry.address, 'ipv6');
}
