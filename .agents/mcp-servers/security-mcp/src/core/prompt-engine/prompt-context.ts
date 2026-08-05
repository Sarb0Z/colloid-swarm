import type { ScanEvidence } from '../../types/scan.types.js';

export interface PromptContext {
  targetUrl: string;
  evidence: ScanEvidence | Record<string, unknown>;
  credentialMode: 'anonymous' | 'single';
}

export function buildContext(input: {
  targetUrl: string;
  evidence: ScanEvidence | Record<string, unknown>;
  credentialMode: 'anonymous' | 'single';
}): PromptContext {
  return {
    targetUrl: input.targetUrl,
    evidence: input.evidence,
    credentialMode: input.credentialMode,
  };
}
