import type { RuntimeConfig } from '../../config/env.js';
import { buildContext } from '../prompt-engine/prompt-context.js';
import { PROMPT_REGISTRY } from '../prompt-engine/prompt-registry.js';
import { SecretRedactor } from '../policy/redaction.js';
import { authorizeTarget } from '../policy/target-policy.js';
import { evaluateMatcher } from '../templates/matchers.js';
import { loadBundledTemplates, loadCommonPaths } from '../templates/template-loader.js';
import type { TemplateRequest } from '../templates/types.js';
import type { Finding } from '../../types/finding.types.js';
import type {
  CoverageBucket,
  DiscoveredEndpoint,
  DiscoveredForm,
  ScanCoverage,
  ScanEvidence,
  ScanPhase,
  ScanResult,
  ScanType,
} from '../../types/scan.types.js';
import {
  authorizedRequest,
  RequestBudget,
  type AuthorizedRequestDependencies,
  type RequestCredentials,
  type RequestOutcome,
} from './http-client.js';

export interface SecurityScanRequest {
  targetUrl: string;
  scanType: ScanType;
  maxDepth?: number;
  includeTemplates?: boolean;
  includeContentDiscovery?: boolean;
  credentials?: RequestCredentials;
}

export interface StructuredScanFailure {
  ok: false;
  phase: ScanPhase;
  targetUrl: string;
  error: string;
  requestCount: number;
  coverage: ScanCoverage;
}

export class ScanExecutionError extends Error {
  constructor(public readonly result: StructuredScanFailure) {
    super(result.error);
    this.name = 'ScanExecutionError';
  }
}

const DIFFERENTIAL_UNTESTED = Object.freeze([
  'access-control.idor',
  'access-control.bola',
  'access-control.bfla',
  'access-control.privilege-escalation',
  'multi-tenant.isolation',
]);

export async function scanTarget(
  request: SecurityScanRequest,
  config: RuntimeConfig,
  dependencies: AuthorizedRequestDependencies = {},
): Promise<ScanResult> {
  const redactor = SecretRedactor.fromCredentials(request.credentials);
  const rootDecision = await authorizeTarget(request.targetUrl, config, dependencies.resolver);
  if (!rootDecision.allowed) throw new Error(`Target rejected: ${rootDecision.reason}`);

  const globalBudget = new RequestBudget(config.maxRequests);
  const requestedDepth = request.maxDepth ?? defaultDepth(request.scanType);
  const maxDepth = Math.min(requestedDepth, config.maxDepth);
  const templateEnabled = request.includeTemplates ?? request.scanType === 'deep';
  const coverage = createCoverage();
  const evidence: ScanEvidence = {
    targetUrl: redactor.scrubUrl(request.targetUrl),
    scanType: request.scanType,
    requestCount: 0,
    pages: [],
    headers: {},
    cookies: {},
    forms: [],
    endpoints: [],
    notes: [],
    coverage,
  };

  coverage.phases.root.attempted += 1;
  let rootOutcome: RequestOutcome;
  try {
    rootOutcome = await authorizedRequest(
      request.targetUrl,
      request.credentials,
      config,
      globalBudget,
      dependencies,
    );
  } catch (error) {
    coverage.phases.root.allocatedRequests = globalBudget.used;
    failScan('root', request.targetUrl, error, evidence, globalBudget, redactor);
  }
  coverage.phases.root.allocatedRequests = globalBudget.used;
  recordSuccess(evidence, rootOutcome, 'target', 'root');

  const remainingAfterRoot = globalBudget.remaining;
  const templateAllocation =
    templateEnabled && remainingAfterRoot > 0
      ? Math.max(1, Math.floor(remainingAfterRoot * 0.4))
      : 0;
  const discoveryAllocation = remainingAfterRoot - templateAllocation;
  coverage.phases.templates.allocatedRequests = templateAllocation;
  allocateDiscovery(coverage, discoveryAllocation, request);
  const crawlBudget = new RequestBudget(coverage.phases.crawl.allocatedRequests, globalBudget);
  const contentBudget = new RequestBudget(
    coverage.phases['content-discovery'].allocatedRequests,
    globalBudget,
  );
  const templateBudget = new RequestBudget(templateAllocation, globalBudget);

  const rootOrigin = new URL(request.targetUrl).origin;
  const queue: Array<{ url: string; depth: number; source: 'link' | 'wordlist' }> = [];
  collectPageDiscoveries(evidence, rootOutcome, 0, maxDepth, rootOrigin, queue);
  if (request.includeContentDiscovery ?? request.scanType === 'deep') {
    let commonPaths: string[];
    try {
      commonPaths = await loadCommonPaths();
    } catch (error) {
      failScan('content-discovery', request.targetUrl, error, evidence, globalBudget, redactor);
    }
    for (const path of commonPaths) {
      queue.push({
        url: new URL(path, request.targetUrl).toString(),
        depth: maxDepth,
        source: 'wordlist',
      });
    }
  }

  const visited = new Set<string>([request.targetUrl]);
  while (queue.length > 0 && (crawlBudget.remaining > 0 || contentBudget.remaining > 0)) {
    const next = queue.shift();
    if (!next || visited.has(next.url)) continue;
    visited.add(next.url);
    const phase: ScanPhase = next.source === 'wordlist' ? 'content-discovery' : 'crawl';
    const phaseBudget = phase === 'content-discovery' ? contentBudget : crawlBudget;
    if (phaseBudget.remaining <= 0) continue;
    coverage.phases[phase].attempted += 1;
    let outcome: RequestOutcome;
    try {
      outcome = await authorizedRequest(
        next.url,
        request.credentials,
        config,
        phaseBudget,
        dependencies,
      );
    } catch (error) {
      recordFailure(evidence, phase, next.url, error, redactor);
      continue;
    }
    recordSuccess(evidence, outcome, next.source, phase);
    collectPageDiscoveries(evidence, outcome, next.depth, maxDepth, rootOrigin, queue);
  }

  let templateFindings: Finding[] = [];
  if (templateEnabled) {
    try {
      templateFindings = await runTemplates(
        request,
        config,
        dependencies,
        templateBudget,
        evidence,
        redactor,
      );
    } catch (error) {
      failScan('templates', request.targetUrl, error, evidence, globalBudget, redactor);
    }
  }
  evidence.requestCount = globalBudget.used;
  const findings = [
    ...templateFindings,
    ...runDeterministicHeuristics(request.targetUrl, evidence, hasCredentials(request.credentials)),
  ];
  return redactor.scrubSerializable({
    ok: true,
    evidence,
    findings,
    limits: {
      maxRequests: config.maxRequests,
      maxDepth: config.maxDepth,
      maxConcurrentRequests: 1,
      maxRedirects: config.maxRedirects,
    },
  });
}

function createCoverage(): ScanCoverage {
  const bucket = (allocatedRequests = 0): CoverageBucket => ({
    allocatedRequests,
    attempted: 0,
    succeeded: 0,
    failed: 0,
    truncated: 0,
  });
  return {
    phases: {
      root: bucket(),
      crawl: bucket(),
      'content-discovery': bucket(),
      templates: bucket(),
    },
    failures: [],
    untested: DIFFERENTIAL_UNTESTED.map((id) => ({
      id,
      reason:
        'The current scan accepts at most one credential and does not run principal-to-principal differential requests.',
    })),
  };
}

function allocateDiscovery(
  coverage: ScanCoverage,
  allocation: number,
  request: SecurityScanRequest,
): void {
  const contentEnabled = request.includeContentDiscovery ?? request.scanType === 'deep';
  if (!contentEnabled) {
    coverage.phases.crawl.allocatedRequests = allocation;
    return;
  }
  const contentAllocation = Math.floor(allocation / 2);
  coverage.phases['content-discovery'].allocatedRequests = contentAllocation;
  coverage.phases.crawl.allocatedRequests = allocation - contentAllocation;
}

function collectPageDiscoveries(
  evidence: ScanEvidence,
  outcome: RequestOutcome,
  depth: number,
  maxDepth: number,
  rootOrigin: string,
  queue: Array<{ url: string; depth: number; source: 'link' | 'wordlist' }>,
): void {
  if (!isHtml(outcome.headers['content-type'])) return;
  evidence.forms.push(...extractForms(outcome.body, outcome.finalUrl));
  evidence.endpoints.push(...extractScriptEndpoints(outcome.body, outcome.finalUrl, rootOrigin));
  if (depth >= maxDepth) return;
  for (const link of extractLinks(outcome.body, outcome.finalUrl)) {
    if (new URL(link).origin === rootOrigin) queue.push({ url: link, depth: depth + 1, source: 'link' });
  }
}

function recordSuccess(
  evidence: ScanEvidence,
  outcome: RequestOutcome,
  source: string,
  phase: ScanPhase,
): void {
  const bucket = evidence.coverage.phases[phase];
  bucket.succeeded += 1;
  if (outcome.truncated) bucket.truncated += 1;
  evidence.pages.push({
    url: outcome.requestedUrl,
    finalUrl: outcome.finalUrl,
    status: outcome.status,
    contentType: outcome.headers['content-type'],
    bytes: outcome.bytes,
    redirected: outcome.redirects > 0,
    truncated: outcome.truncated,
    bodyLimitBytes: outcome.bodyLimitBytes,
  });
  evidence.headers[outcome.finalUrl] = outcome.headers;
  if (outcome.setCookies.length > 0) evidence.cookies[outcome.finalUrl] = outcome.setCookies;
  evidence.endpoints.push({ url: outcome.finalUrl, method: 'GET', source });
}

function recordFailure(
  evidence: ScanEvidence,
  phase: ScanPhase,
  rawUrl: string,
  error: unknown,
  redactor: SecretRedactor,
): void {
  const message = safeError(error, redactor);
  evidence.coverage.phases[phase].failed += 1;
  evidence.coverage.failures.push({ phase, url: redactor.scrubUrl(rawUrl), error: message });
}

function failScan(
  phase: ScanPhase,
  rawUrl: string,
  error: unknown,
  evidence: ScanEvidence,
  budget: RequestBudget,
  redactor: SecretRedactor,
): never {
  recordFailure(evidence, phase, rawUrl, error, redactor);
  evidence.requestCount = budget.used;
  const message = safeError(error, redactor);
  throw new ScanExecutionError(
    redactor.scrubSerializable({
      ok: false,
      phase,
      targetUrl: redactor.scrubUrl(rawUrl),
      error: message,
      requestCount: budget.used,
      coverage: evidence.coverage,
    }),
  );
}

async function runTemplates(
  request: SecurityScanRequest,
  config: RuntimeConfig,
  dependencies: AuthorizedRequestDependencies,
  budget: RequestBudget,
  evidence: ScanEvidence,
  redactor: SecretRedactor,
): Promise<Finding[]> {
  const templates = await loadBundledTemplates();
  const findings: Finding[] = [];
  for (const template of templates) {
    for (const templateRequest of template.requests) {
      if (budget.remaining <= 0) return findings;
      if (!isSafeTemplateRequest(templateRequest)) continue;
      for (const path of templateRequest.paths ?? ['/']) {
        if (budget.remaining <= 0) return findings;
        const url = new URL(path, request.targetUrl).toString();
        evidence.coverage.phases.templates.attempted += 1;
        let outcome: RequestOutcome;
        try {
          outcome = await authorizedRequest(url, request.credentials, config, budget, dependencies);
        } catch (error) {
          recordFailure(evidence, 'templates', url, error, redactor);
          continue;
        }
        evidence.coverage.phases.templates.succeeded += 1;
        if (outcome.truncated) evidence.coverage.phases.templates.truncated += 1;
        const evaluations = templateRequest.matchers.map((matcher) =>
          evaluateMatcher(matcher, {
            status: outcome.status,
            headers: outcome.headers,
            body: outcome.body,
          }),
        );
        const matched =
          (templateRequest.matchersCondition ?? 'or') === 'and'
            ? evaluations.every((result) => result.matched)
            : evaluations.some((result) => result.matched);
        if (matched) findings.push(templateFinding(template, templateRequest, outcome, redactor));
      }
    }
  }
  return findings;
}

function templateFinding(
  template: Awaited<ReturnType<typeof loadBundledTemplates>>[number],
  templateRequest: TemplateRequest,
  outcome: RequestOutcome,
  redactor: SecretRedactor,
): Finding {
  const safeUrl = redactor.scrubUrl(outcome.finalUrl);
  return {
    id: `template.${template.id}.${stableHash(safeUrl)}`,
    title: template.info.name,
    severity: template.info.severity,
    category: template.info.tags?.[0] ?? 'configuration',
    description: template.info.description ?? `Template ${template.id} matched.`,
    evidence: {
      templateId: template.id,
      url: safeUrl,
      status: outcome.status,
      truncated: outcome.truncated,
      matcherTypes: templateRequest.matchers.map((matcher) => matcher.type),
    },
    impact: template.info.description ?? 'The response matched a tracked security check.',
    remediation: template.info.reference?.[0]
      ? `Review ${template.info.reference[0]} and remove the exposed condition.`
      : 'Remove the exposed condition and verify the endpoint access policy.',
    confidence: template.confidence ?? 'medium',
    promptId: `template.${template.id}`,
  };
}

function runDeterministicHeuristics(
  targetUrl: string,
  evidence: ScanEvidence,
  authenticated: boolean,
): Finding[] {
  const context = buildContext({
    targetUrl,
    evidence,
    credentialMode: authenticated ? 'single' : 'anonymous',
  });
  const findings: Finding[] = [];
  for (const prompt of PROMPT_REGISTRY) {
    const generated = prompt.heuristic?.(context) ?? [];
    for (let index = 0; index < generated.length; index += 1) {
      const finding = generated[index];
      if (finding) findings.push({ ...finding, id: `${prompt.id}.${index + 1}`, promptId: prompt.id });
    }
  }
  return findings;
}

function safeError(error: unknown, redactor: SecretRedactor): string {
  return redactor.scrub(error instanceof Error ? error.message : 'Request failed');
}

function hasCredentials(credentials: RequestCredentials | undefined): boolean {
  return Boolean(
    credentials?.bearerToken ||
      Object.values(credentials?.cookies ?? {}).some((value) => value.length > 0),
  );
}

function defaultDepth(scanType: ScanType): number {
  if (scanType === 'quick') return 0;
  if (scanType === 'standard') return 1;
  return 3;
}

function isSafeTemplateRequest(request: TemplateRequest): boolean {
  return (request.method ?? 'GET').toUpperCase() === 'GET' && request.body === undefined;
}

function isHtml(contentType: string | undefined): boolean {
  return contentType?.toLowerCase().includes('text/html') ?? false;
}

const linkPattern = /<a\b[^>]*?\bhref\s*=\s*["']([^"']+)["'][^>]*>/gi;
const formPattern = /<form\b([^>]*)>([\s\S]*?)<\/form>/gi;
const actionPattern = /\baction\s*=\s*["']([^"']*)["']/i;
const methodPattern = /\bmethod\s*=\s*["']([^"']*)["']/i;
const fieldPattern = /<(?:input|select|textarea)\b[^>]*?\bname\s*=\s*["']([^"']+)["']/gi;
const endpointPattern = /\b(?:fetch|axios\.(?:get|post|put|delete|patch))\s*\(\s*["']([^"']+)["']/gi;

function extractLinks(html: string, base: string): string[] {
  const result: string[] = [];
  for (const match of html.matchAll(linkPattern)) {
    const raw = match[1];
    if (!raw) continue;
    const url = httpUrl(raw, base);
    if (url) result.push(url);
  }
  return result;
}

function extractForms(html: string, pageUrl: string): DiscoveredForm[] {
  const result: DiscoveredForm[] = [];
  for (const match of html.matchAll(formPattern)) {
    const attributes = match[1] ?? '';
    const body = match[2] ?? '';
    const rawAction = actionPattern.exec(attributes)?.[1];
    const fields = [...body.matchAll(fieldPattern)].flatMap((field) => (field[1] ? [field[1]] : []));
    result.push({
      pageUrl,
      action: rawAction ? new URL(rawAction, pageUrl).toString() : undefined,
      method: (methodPattern.exec(attributes)?.[1] ?? 'GET').toUpperCase(),
      fields,
    });
  }
  return result;
}

function extractScriptEndpoints(html: string, base: string, rootOrigin: string): DiscoveredEndpoint[] {
  const result: DiscoveredEndpoint[] = [];
  for (const match of html.matchAll(endpointPattern)) {
    const raw = match[1];
    if (!raw) continue;
    const url = httpUrl(raw, base);
    if (url && new URL(url).origin === rootOrigin) {
      result.push({ url, method: 'GET', source: 'inline-script' });
    }
  }
  return result;
}

function httpUrl(raw: string, base: string): string | undefined {
  try {
    const url = new URL(raw, base);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return undefined;
    url.hash = '';
    return url.toString();
  } catch {
    return undefined;
  }
}

function stableHash(value: string): string {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = (Math.imul(hash, 31) + value.charCodeAt(index)) | 0;
  }
  return (hash >>> 0).toString(36);
}
