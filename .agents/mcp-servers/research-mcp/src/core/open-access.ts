import type { RuntimeConfig } from '../config/env.js';
import type { Fetcher } from './http-client.js';

// Published rates, honoured rather than discovered by getting blocked.
// Crossref: 50/s polite pool, but list queries are the expensive shape and the
// service asks callers to stay modest — one every 200ms is well inside it.
// arXiv: the terms of use state one request every three seconds, single
// connection. That number is theirs, not a guess.
const CROSSREF_INTERVAL_MS = 200;
const ARXIV_INTERVAL_MS = 3_000;
const UNPAYWALL_INTERVAL_MS = 200;

export interface OpenAccessLocation {
  url: string;
  kind: 'pdf' | 'html' | 'landing';
  source: 'unpaywall' | 'arxiv';
  license: string | null;
  repository: string | null;
}

export interface WorkCandidate {
  title: string;
  doi: string | null;
  authors: readonly string[];
  year: number | null;
  publisher: string | null;
  /**
   * Crossref's own relevance score. Bibliographic search is fuzzy — asking for
   * a famous title routinely returns a different paper that merely cites it —
   * so the caller must see the matched title and decide, not trust rank 1.
   */
  score: number | null;
  openAccess: readonly OpenAccessLocation[];
}

const DOI_PATTERN = /\b(10\.\d{4,9}\/[-._;()/:A-Z0-9]+)\b/i;

export class OpenAccessResolver {
  constructor(
    private readonly http: Fetcher,
    private readonly config: RuntimeConfig,
  ) {}

  async resolve(query: string, limit: number): Promise<{
    candidates: WorkCandidate[];
    matchedBy: 'doi' | 'title';
    notes: string[];
  }> {
    const notes: string[] = [];
    const doi = DOI_PATTERN.exec(query)?.[1];
    const matched = doi
      ? await this.byDoi(doi, notes)
      : await this.byTitle(query, limit, notes);

    const candidates: WorkCandidate[] = [];
    for (const candidate of matched) {
      const locations: OpenAccessLocation[] = [];
      if (candidate.doi) locations.push(...(await this.unpaywall(candidate.doi, notes)));
      locations.push(...(await this.arxiv(candidate.title, candidate.doi, notes)));
      candidates.push({ ...candidate, openAccess: dedupe(locations) });
    }
    return { candidates, matchedBy: doi ? 'doi' : 'title', notes };
  }

  private async byDoi(doi: string, notes: string[]): Promise<WorkCandidate[]> {
    const url = `https://api.crossref.org/works/${encodeURIComponent(doi)}${this.mailto('?')}`;
    try {
      const response = await this.http.fetch(url, { intervalMs: CROSSREF_INTERVAL_MS });
      const body: unknown = JSON.parse(response.text);
      const message = pick(body, 'message');
      const candidate = toCandidate(message, null);
      return candidate ? [candidate] : [];
    } catch (error) {
      notes.push(`Crossref DOI lookup failed: ${(error as Error).message}`);
      return [];
    }
  }

  private async byTitle(query: string, limit: number, notes: string[]): Promise<WorkCandidate[]> {
    const url =
      'https://api.crossref.org/works?rows=' +
      String(limit) +
      '&select=DOI,title,author,issued,publisher,score' +
      '&query.bibliographic=' +
      encodeURIComponent(query) +
      this.mailto('&');
    try {
      const response = await this.http.fetch(url, { intervalMs: CROSSREF_INTERVAL_MS });
      const body: unknown = JSON.parse(response.text);
      const items = pick(pick(body, 'message'), 'items');
      if (!Array.isArray(items)) return [];
      notes.push(
        'Crossref bibliographic matching is fuzzy; compare each returned title against what you asked for.',
      );
      return items
        .map((item) => toCandidate(item, numberOrNull(pick(item, 'score'))))
        .filter((item): item is WorkCandidate => item !== null);
    } catch (error) {
      notes.push(`Crossref search failed: ${(error as Error).message}`);
      return [];
    }
  }

  private async unpaywall(doi: string, notes: string[]): Promise<OpenAccessLocation[]> {
    if (!this.config.contactEmail) {
      notes.push(
        'Unpaywall skipped: set RESEARCH_MCP_CONTACT_EMAIL to a real mailbox to enable open-access lookup.',
      );
      return [];
    }
    const url = `https://api.unpaywall.org/v2/${encodeURIComponent(doi)}?email=${encodeURIComponent(this.config.contactEmail)}`;
    try {
      const response = await this.http.fetch(url, { intervalMs: UNPAYWALL_INTERVAL_MS });
      const body: unknown = JSON.parse(response.text);
      const locations = pick(body, 'oa_locations');
      if (!Array.isArray(locations)) return [];
      return locations.flatMap((entry): OpenAccessLocation[] => {
        const pdf = stringOrNull(pick(entry, 'url_for_pdf'));
        const landing = stringOrNull(pick(entry, 'url_for_landing_page'));
        const target = pdf ?? landing ?? stringOrNull(pick(entry, 'url'));
        if (!target) return [];
        return [{
          url: target,
          kind: pdf ? 'pdf' : 'landing',
          source: 'unpaywall',
          license: stringOrNull(pick(entry, 'license')),
          repository: stringOrNull(pick(entry, 'repository_institution')),
        }];
      });
    } catch (error) {
      notes.push(`Unpaywall lookup failed: ${(error as Error).message}`);
      return [];
    }
  }

  private async arxiv(
    title: string,
    doi: string | null,
    notes: string[],
  ): Promise<OpenAccessLocation[]> {
    if (!title) return [];
    const url =
      'https://export.arxiv.org/api/query?max_results=1&search_query=ti:' +
      encodeURIComponent(`"${title.replace(/["\\]/g, ' ')}"`);
    try {
      const response = await this.http.fetch(url, { intervalMs: ARXIV_INTERVAL_MS });
      const entry = /<entry>([\s\S]*?)<\/entry>/.exec(response.text)?.[1];
      if (!entry) return [];
      const found = /<title>([\s\S]*?)<\/title>/.exec(entry)?.[1]?.replace(/\s+/g, ' ').trim();
      if (!found || !sameTitle(found, title)) return [];
      // A title alone is not identity. Generic titles ("Deep learning") match
      // unrelated preprints, and offering one as the open copy of a different
      // paper is a citation error. When the work has a DOI, arXiv must claim
      // the same DOI; without one, an exact title is the best available link.
      const entryDoi = /<arxiv:doi[^>]*>([^<]+)<\/arxiv:doi>/
        .exec(entry)?.[1]
        ?.trim()
        .toLowerCase();
      if (doi && entryDoi !== doi.trim().toLowerCase()) return [];
      const pdf = /href="([^"]*\/pdf\/[^"]*)"/.exec(entry)?.[1];
      if (!pdf) return [];
      return [{ url: pdf, kind: 'pdf', source: 'arxiv', license: null, repository: 'arXiv' }];
    } catch (error) {
      notes.push(`arXiv lookup failed: ${(error as Error).message}`);
      return [];
    }
  }

  private mailto(separator: string): string {
    return this.config.contactEmail
      ? `${separator}mailto=${encodeURIComponent(this.config.contactEmail)}`
      : '';
  }
}

function normalise(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

export function sameTitle(left: string, right: string): boolean {
  return normalise(left) === normalise(right);
}

function dedupe(locations: readonly OpenAccessLocation[]): OpenAccessLocation[] {
  const seen = new Set<string>();
  const result: OpenAccessLocation[] = [];
  for (const location of locations) {
    if (seen.has(location.url)) continue;
    seen.add(location.url);
    result.push(location);
  }
  // PDFs first: they are the readable copy, landing pages usually are not.
  return result.sort((left, right) => Number(right.kind === 'pdf') - Number(left.kind === 'pdf'));
}

function pick(value: unknown, key: string): unknown {
  return typeof value === 'object' && value !== null
    ? (value as Record<string, unknown>)[key]
    : undefined;
}

function stringOrNull(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

function numberOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function toCandidate(raw: unknown, score: number | null): WorkCandidate | null {
  const titles = pick(raw, 'title');
  const title = Array.isArray(titles) ? stringOrNull(titles[0]) : stringOrNull(titles);
  if (!title) return null;
  const authors = pick(raw, 'author');
  const issued = pick(pick(raw, 'issued'), 'date-parts');
  const year = Array.isArray(issued) && Array.isArray(issued[0])
    ? numberOrNull(issued[0][0])
    : null;
  return {
    title: title.replace(/\s+/g, ' ').trim(),
    doi: stringOrNull(pick(raw, 'DOI')),
    authors: Array.isArray(authors)
      ? authors
          .map((author) => {
            const family = stringOrNull(pick(author, 'family'));
            const given = stringOrNull(pick(author, 'given'));
            return [given, family].filter(Boolean).join(' ');
          })
          .filter((name) => name.length > 0)
      : [],
    year,
    publisher: stringOrNull(pick(raw, 'publisher')),
    score,
    openAccess: [],
  };
}
