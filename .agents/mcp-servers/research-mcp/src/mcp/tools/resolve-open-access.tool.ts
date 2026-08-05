import { z } from 'zod';
import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import type { RuntimeConfig } from '../../config/env.js';
import type { Fetcher } from '../../core/http-client.js';
import { OpenAccessResolver, type WorkCandidate } from '../../core/open-access.js';

export const resolveOpenAccessInputSchema = z.object({
  query: z.string().min(3).describe('A DOI, or a paper title / bibliographic string.'),
  limit: z.number().int().min(1).max(10).default(3).describe('Candidates to return for a title query.'),
});

export type ResolveOpenAccessInput = z.infer<typeof resolveOpenAccessInputSchema>;

export const resolveOpenAccessToolDefinition: Tool = {
  name: 'resolve_open_access',
  description:
    'Resolve a DOI or paper title to its legally readable open-access copies (Crossref for the record, ' +
    'Unpaywall and arXiv for the full text). Use before citing a paper, or when a publisher page is paywalled: ' +
    'it returns PDF and repository links that fetch_readable can then read. Title matching is fuzzy, so it ' +
    'returns ranked candidates for you to check rather than a single answer.',
  inputSchema: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'A DOI, or a paper title / bibliographic string.' },
      limit: { type: 'number', default: 3, description: 'Candidates to return for a title query.' },
    },
    required: ['query'],
  },
};

export interface OpenAccessResult {
  ok: boolean;
  query: string;
  matchedBy: 'doi' | 'title';
  candidates: readonly WorkCandidate[];
  notes: string[];
}

export async function handleResolveOpenAccess(
  input: ResolveOpenAccessInput,
  http: Fetcher,
  config: RuntimeConfig,
): Promise<OpenAccessResult> {
  const resolver = new OpenAccessResolver(http, config);
  const { candidates, matchedBy, notes } = await resolver.resolve(input.query, input.limit);
  if (candidates.length === 0) {
    notes.push('No Crossref record matched. For preprints and reports, try fetch_readable on the source URL.');
  }
  if (candidates.length > 0 && candidates.every((candidate) => candidate.openAccess.length === 0)) {
    notes.push('No open-access copy located. The work may be paywalled; check an institutional subscription.');
  }
  return {
    ok: true,
    query: input.query,
    matchedBy,
    candidates,
    notes,
  };
}
