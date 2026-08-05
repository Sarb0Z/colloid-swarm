import { z } from 'zod';
import { getConfig } from '../../config/env.js';
import { authorizeTarget, type Resolver } from '../../core/policy/target-policy.js';

export const validateTargetInputSchema = z
  .object({ targetUrl: z.string().min(1, 'targetUrl is required') })
  .strict();

export const validateTargetToolDefinition = {
  name: 'validate_target',
  description:
    'Validate a URL against the operator-owned target policy and DNS address policy. This tool does not send a network request.',
  inputSchema: {
    type: 'object',
    properties: { targetUrl: { type: 'string', description: 'The URL to validate.' } },
    required: ['targetUrl'],
    additionalProperties: false,
  },
} as const;

export async function handleValidateTarget(
  input: z.infer<typeof validateTargetInputSchema>,
  resolver?: Resolver,
) {
  const decision = await authorizeTarget(input.targetUrl, getConfig(), resolver);
  return {
    allowed: decision.allowed,
    reason: decision.reason,
    normalizedUrl: decision.normalizedUrl,
    classification: decision.classification,
  };
}
