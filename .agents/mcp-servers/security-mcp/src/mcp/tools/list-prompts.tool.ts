import { z } from 'zod';
import { PROMPT_REGISTRY } from '../../core/prompt-engine/prompt-registry.js';

export const listPromptsInputSchema = z
  .object({
    category: z.string().min(1).optional(),
    ids: z.array(z.string().min(1)).max(100).optional(),
  })
  .strict();

export const listPromptsToolDefinition = {
  name: 'list_security_prompts',
  description:
    'Return the deterministic security prompt catalog for the calling agent to apply to security_scan evidence.',
  inputSchema: {
    type: 'object',
    properties: {
      category: { type: 'string', description: 'Return only this exact category.' },
      ids: {
        type: 'array',
        maxItems: 100,
        items: { type: 'string' },
        description: 'Return only these exact prompt IDs.',
      },
    },
    additionalProperties: false,
  },
} as const;

export function handleListPrompts(input: z.infer<typeof listPromptsInputSchema>) {
  const ids = input.ids ? new Set(input.ids) : undefined;
  const prompts = PROMPT_REGISTRY.filter(
    (prompt) =>
      (!input.category || prompt.category === input.category) && (!ids || ids.has(prompt.id)),
  ).map(({ id, title, category, severityFocus, prompt }) => ({
    id,
    title,
    category,
    severityFocus,
    prompt,
  }));
  return {
    count: prompts.length,
    prompts,
    usage:
      'Apply each prompt to the structured evidence returned by security_scan. Keep credentials out of findings and persist reports only through the repository security workflow.',
  };
}
