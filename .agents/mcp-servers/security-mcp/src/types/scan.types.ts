import type { Finding } from './finding.types.js';

export type ScanType = 'quick' | 'standard' | 'deep';

export interface ScannedPage {
  url: string;
  finalUrl: string;
  status: number;
  contentType?: string;
  bytes: number;
  redirected: boolean;
  truncated: boolean;
  bodyLimitBytes: number;
}

export interface DiscoveredForm {
  pageUrl: string;
  action?: string;
  method: string;
  fields: string[];
}

export interface DiscoveredEndpoint {
  url: string;
  method: string;
  source: string;
}

export type ScanPhase = 'root' | 'crawl' | 'content-discovery' | 'templates';

export interface CoverageBucket {
  allocatedRequests: number;
  attempted: number;
  succeeded: number;
  failed: number;
  truncated: number;
}

export interface ScanFailure {
  phase: ScanPhase;
  url: string;
  error: string;
}

export interface UntestedClass {
  id: string;
  reason: string;
}

export interface ScanCoverage {
  phases: Record<ScanPhase, CoverageBucket>;
  failures: ScanFailure[];
  untested: UntestedClass[];
}

export interface ScanEvidence {
  targetUrl: string;
  scanType: ScanType;
  requestCount: number;
  pages: ScannedPage[];
  headers: Record<string, Record<string, string>>;
  cookies: Record<string, string[]>;
  forms: DiscoveredForm[];
  endpoints: DiscoveredEndpoint[];
  notes: string[];
  coverage: ScanCoverage;
}

export interface ScanResult {
  ok: true;
  evidence: ScanEvidence;
  findings: Finding[];
  limits: {
    maxRequests: number;
    maxDepth: number;
    maxConcurrentRequests: 1;
    maxRedirects: number;
  };
}
