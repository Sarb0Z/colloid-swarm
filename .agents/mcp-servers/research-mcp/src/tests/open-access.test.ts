import { describe, expect, it } from 'vitest';
import type { RuntimeConfig } from '../config/env.js';
import type { Fetcher, FetchResult } from '../core/http-client.js';
import { OpenAccessResolver, sameTitle } from '../core/open-access.js';

const config = (contactEmail: string | null): RuntimeConfig => ({
  contactEmail,
  userAgent: 'test',
  requestTimeoutMs: 1_000,
  maxBodyBytes: 1_024,
  maxRedirects: 1,
  minHostIntervalMs: 0,
});

const reply = (text: string): FetchResult => ({
  url: 'https://stub/', status: 200, contentType: 'application/json',
  text, bytes: Buffer.from(text), truncated: false, redirects: [],
});

/** Routes by hostname so each upstream can be scripted independently. */
function stub(routes: Record<string, string>): Fetcher & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    async fetch(url: string) {
      calls.push(url);
      const host = new URL(url).hostname;
      const body = routes[host];
      if (body === undefined) throw new Error(`unexpected host ${host}`);
      return reply(body);
    },
  };
}

const crossrefWork = (doi: string, title: string) =>
  JSON.stringify({ message: { DOI: doi, title: [title], publisher: 'Nature', issued: { 'date-parts': [[2015]] }, author: [{ given: 'Yann', family: 'LeCun' }] } });

const arxivEntry = (title: string, doi?: string) =>
  `<feed><entry><title>${title}</title>${doi ? `<arxiv:doi>${doi}</arxiv:doi>` : ''}` +
  `<link title="pdf" href="https://arxiv.org/pdf/1807.07987v2"/></entry></feed>`;

describe('OpenAccessResolver', () => {
  it('rejects an arXiv hit whose DOI does not match the work', async () => {
    // "Deep learning" matches unrelated preprints by title alone. Offering one
    // as the open copy of the Nature paper is a citation error.
    const http = stub({
      'api.crossref.org': crossrefWork('10.1038/nature14539', 'Deep learning'),
      'export.arxiv.org': arxivEntry('Deep learning', '10.1145/3065386'),
    });
    const { candidates } = await new OpenAccessResolver(http, config(null)).resolve(
      '10.1038/nature14539', 1,
    );
    expect(candidates[0]?.doi).toBe('10.1038/nature14539');
    expect(candidates[0]?.openAccess).toEqual([]);
  });

  it('rejects an arXiv hit that reports no DOI when the work has one', async () => {
    const http = stub({
      'api.crossref.org': crossrefWork('10.1038/nature14539', 'Deep learning'),
      'export.arxiv.org': arxivEntry('Deep learning'),
    });
    const { candidates } = await new OpenAccessResolver(http, config(null)).resolve(
      '10.1038/nature14539', 1,
    );
    expect(candidates[0]?.openAccess).toEqual([]);
  });

  it('accepts an arXiv hit that claims the same DOI', async () => {
    const http = stub({
      'api.crossref.org': crossrefWork('10.1145/3065386', 'Attention is all you need'),
      'export.arxiv.org': arxivEntry('Attention is all you need', '10.1145/3065386'),
    });
    const { candidates } = await new OpenAccessResolver(http, config(null)).resolve(
      '10.1145/3065386', 1,
    );
    expect(candidates[0]?.openAccess).toEqual([
      { url: 'https://arxiv.org/pdf/1807.07987v2', kind: 'pdf', source: 'arxiv', license: null, repository: 'arXiv' },
    ]);
  });

  it('rejects an arXiv hit whose title differs', async () => {
    const http = stub({
      'api.crossref.org': crossrefWork('10.1038/nature14539', 'Deep learning'),
      'export.arxiv.org': arxivEntry('Something else entirely', '10.1038/nature14539'),
    });
    const { candidates } = await new OpenAccessResolver(http, config(null)).resolve(
      '10.1038/nature14539', 1,
    );
    expect(candidates[0]?.openAccess).toEqual([]);
  });

  it('skips Unpaywall and says so when no contact email is configured', async () => {
    const http = stub({
      'api.crossref.org': crossrefWork('10.1038/nature14539', 'Deep learning'),
      'export.arxiv.org': '<feed></feed>',
    });
    const { notes } = await new OpenAccessResolver(http, config(null)).resolve('10.1038/nature14539', 1);
    expect(notes.some((note) => note.includes('RESEARCH_MCP_CONTACT_EMAIL'))).toBe(true);
    expect(http.calls.some((url) => url.includes('unpaywall'))).toBe(false);
  });

  it('queries Unpaywall with the configured email and returns its locations, PDFs first', async () => {
    const http = stub({
      'api.crossref.org': crossrefWork('10.1038/nature14539', 'Deep learning'),
      'export.arxiv.org': '<feed></feed>',
      'api.unpaywall.org': JSON.stringify({
        oa_locations: [
          { url_for_landing_page: 'https://repo.example/record/1', license: 'cc-by', repository_institution: 'Example' },
          { url_for_pdf: 'https://repo.example/record/1.pdf', license: 'cc-by', repository_institution: 'Example' },
        ],
      }),
    });
    const { candidates } = await new OpenAccessResolver(http, config('real@institution.edu')).resolve(
      '10.1038/nature14539', 1,
    );
    expect(http.calls.some((url) => url.includes('email=real%40institution.edu'))).toBe(true);
    expect(candidates[0]?.openAccess.map((location) => location.kind)).toEqual(['pdf', 'landing']);
  });

  it('sends the polite-pool mailto to Crossref when configured', async () => {
    const http = stub({
      'api.crossref.org': crossrefWork('10.1/x', 'T'),
      'export.arxiv.org': '<feed></feed>',
      'api.unpaywall.org': '{}',
    });
    await new OpenAccessResolver(http, config('real@institution.edu')).resolve('10.1/x', 1);
    expect(http.calls[0]).toContain('mailto=real%40institution.edu');
  });

  it('surfaces ranked title candidates rather than asserting the top hit', async () => {
    const http = stub({
      'api.crossref.org': JSON.stringify({
        message: {
          items: [
            { DOI: '10.1/a', title: ['Is Attention All You Need?'], score: 88.1, issued: { 'date-parts': [[2025]] } },
            { DOI: '10.1/b', title: ['Attention Is All You Need'], score: 84.0, issued: { 'date-parts': [[2017]] } },
          ],
        },
      }),
      'export.arxiv.org': '<feed></feed>',
    });
    const { candidates, notes } = await new OpenAccessResolver(http, config(null)).resolve(
      'Attention is all you need', 2,
    );
    expect(candidates.map((candidate) => candidate.title)).toEqual([
      'Is Attention All You Need?',
      'Attention Is All You Need',
    ]);
    expect(candidates[0]?.score).toBe(88.1);
    expect(notes.some((note) => note.includes('fuzzy'))).toBe(true);
  });

  it('degrades to an empty result when Crossref fails', async () => {
    const http: Fetcher = { async fetch() { throw new Error('upstream down'); } };
    const { candidates, notes } = await new OpenAccessResolver(http, config(null)).resolve('10.1/x', 1);
    expect(candidates).toEqual([]);
    expect(notes.some((note) => note.includes('upstream down'))).toBe(true);
  });
});

describe('sameTitle', () => {
  it('ignores case, punctuation and spacing', () => {
    expect(sameTitle('Attention Is All You Need', 'attention is all you need')).toBe(true);
    expect(sameTitle('Deep-Learning!', 'deep learning')).toBe(true);
  });
  it('separates distinct titles', () => {
    expect(sameTitle('Is Attention All You Need?', 'Attention Is All You Need')).toBe(false);
  });
});
