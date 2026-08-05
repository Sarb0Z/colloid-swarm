import { z } from 'zod';
import { getConfig } from '../../config/env.js';
import { scanTarget, type SecurityScanRequest } from '../../core/scanner/scanner.js';
import type { AuthorizedRequestDependencies } from '../../core/scanner/http-client.js';

const credentialsSchema = z
  .object({
    bearerToken: z.string().min(1).max(16_384).optional(),
    cookies: z.record(z.string().min(1).max(256), z.string().max(16_384)).optional(),
  })
  .strict();

export const securityScanInputSchema = z
  .object({
    targetUrl: z.string().min(1),
    scanType: z.enum(['quick', 'standard', 'deep']),
    maxDepth: z.number().int().min(0).max(3).optional(),
    includeTemplates: z.boolean().optional(),
    includeContentDiscovery: z.boolean().optional(),
    credentials: credentialsSchema.optional(),
  })
  .strict();

export const securityScanToolDefinition = {
  name: 'security_scan',
  description:
    'Run a bounded read-only scan against loopback or an exact operator-configured staging host. Return redacted structured evidence and deterministic findings in memory.',
  inputSchema: {
    type: 'object',
    properties: {
      targetUrl: { type: 'string' },
      scanType: { type: 'string', enum: ['quick', 'standard', 'deep'] },
      maxDepth: { type: 'integer', minimum: 0, maximum: 3 },
      includeTemplates: { type: 'boolean' },
      includeContentDiscovery: { type: 'boolean' },
      credentials: {
        type: 'object',
        properties: {
          bearerToken: { type: 'string', maxLength: 16_384 },
          cookies: {
            type: 'object',
            additionalProperties: { type: 'string', maxLength: 16_384 },
          },
        },
        additionalProperties: false,
      },
    },
    required: ['targetUrl', 'scanType'],
    additionalProperties: false,
  },
} as const;

export async function handleSecurityScan(
  input: z.infer<typeof securityScanInputSchema>,
  dependencies?: AuthorizedRequestDependencies,
) {
  return await scanTarget(input as SecurityScanRequest, getConfig(), dependencies);
}
