import { z } from 'zod';
import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { FetchError, type Fetcher, isBinary } from '../../core/http-client.js';
import { detectChallenge } from '../../core/challenge.js';
import type { ArticleLink } from '../../core/readable.js';
import { canonicalUrl, extractArticle, extractPdfText } from '../../core/readable.js';
import { findSnapshot } from '../../core/wayback.js';

export const fetchReadableInputSchema = z.object({
  url: z.string().min(1).describe('Absolute http(s) URL to read.'),
  archived: z
    .boolean()
    .default(false)
    .describe('Read the Wayback capture instead of the live page. Use for dead or changed URLs.'),
  archivedBefore: z
    .string()
    .regex(/^\d{4,14}$/)
    .optional()
    .describe('Wayback timestamp (YYYYMMDDhhmmss, or any prefix) — take the newest capture at or before it.'),
  maxChars: z
    .number()
    .int()
    .min(500)
    .max(500_000)
    .default(120_000)
    .describe('Cap on returned characters. Text is cut at this length and flagged.'),
});

export type FetchReadableInput = z.infer<typeof fetchReadableInputSchema>;

export const fetchReadableToolDefinition: Tool = {
  name: 'fetch_readable',
  description:
    'Fetch a web page or PDF and return its main text with the navigation, advertising and boilerplate removed. ' +
    'Use instead of a raw fetch when the goal is to read an article, paper or documentation page: it returns a ' +
    'fraction of the tokens and keeps title, byline, site name and publication date. Handles PDFs. Set archived ' +
    'to read a Wayback capture when a URL is dead or has changed.',
  inputSchema: {
    type: 'object',
    properties: {
      url: { type: 'string', description: 'Absolute http(s) URL to read.' },
      archived: {
        type: 'boolean',
        default: false,
        description: 'Read the Wayback capture instead of the live page.',
      },
      archivedBefore: {
        type: 'string',
        description: 'Wayback timestamp (YYYYMMDDhhmmss or a prefix); newest capture at or before it.',
      },
      maxChars: {
        type: 'number',
        default: 120_000,
        description: 'Cap on returned characters.',
      },
    },
    required: ['url'],
  },
};

export interface ReadableResult {
  ok: boolean;
  url: string;
  requestedUrl: string;
  source: 'live' | 'archive';
  contentType: string;
  canonicalUrl?: string | null;
  archiveTimestamp?: string;
  title?: string | null;
  byline?: string | null;
  siteName?: string | null;
  publishedTime?: string | null;
  lang?: string | null;
  excerpt?: string | null;
  links?: readonly ArticleLink[];
  pages?: number;
  text?: string;
  chars?: number;
  /** Text was cut at `maxChars`. Re-request with a larger cap to see the rest. */
  truncated?: boolean;
  /**
   * The response itself hit the byte cap, so the document was incomplete before
   * extraction ran. Distinct from `truncated`: raising `maxChars` will not
   * recover this, and the extracted text may be missing content entirely.
   */
  bodyTruncated?: boolean;
  redirects?: readonly string[];
  notes: string[];
  error?: string;
  /**
   * Why the read failed, when it did. A caller's next move differs per class
   * and cannot be recovered from the message: `blocked` and `server_error` are
   * worth another attempt later or from elsewhere, `not_found` and `policy`
   * never are.
   */
  failure?: FailureClass;
  /** Requests actually sent, so a caller summarising a sweep need not guess. */
  attempts?: number;
}

export type FailureClass =
  | 'blocked'
  | 'not_found'
  | 'server_error'
  | 'client_error'
  | 'timeout'
  | 'network'
  | 'policy'
  | 'size'
  | 'unsupported';

/**
 * Buckets a transport failure by what a caller would do about it.
 *
 * `403`, `429` and `503` go together: all three are the origin refusing *us*,
 * which is never evidence the page is gone. Conflating them with `404` is the
 * mistake career-ops documents at length, where a throttled board was recorded
 * as expired and then skipped indefinitely.
 */
export function classifyFailure(error: FetchError): FailureClass {
  if (error.kind === 'policy') return 'policy';
  if (error.kind === 'size') return 'size';
  if (error.kind === 'budget') return 'timeout';
  if (error.kind === 'network') {
    return /timed out/i.test(error.message) ? 'timeout' : 'network';
  }
  const status = error.status;
  // A redirect loop or an exhausted hop count is `http` with no status. It is
  // the chain being wrong, not this request, so it must not land in
  // `client_error` and be read as "never worth trying again".
  if (status === undefined) return 'network';
  if (status === 404 || status === 410) return 'not_found';
  if (status === 403 || status === 429 || status === 503) return 'blocked';
  if (status >= 500) return 'server_error';
  return 'client_error';
}

export async function handleFetchReadable(
  input: FetchReadableInput,
  http: Fetcher,
): Promise<ReadableResult> {
  const notes: string[] = [];
  let source: 'live' | 'archive' = input.archived ? 'archive' : 'live';
  let archiveTimestamp: string | undefined;
  let target = input.url;
  /**
   * The address the captured bytes were originally served from. Links and the
   * canonical tag must resolve against it: a capture is fetched from
   * web.archive.org, so resolving `/jobs?page=2` against the fetch URL yields an
   * archive path that was never captured and does not exist.
   */
  let archiveOriginal: string | undefined;

  if (input.archived) {
    const snapshot = await findSnapshot(http, input.url, input.archivedBefore);
    if (!snapshot) {
      return {
        ok: false, url: input.url, requestedUrl: input.url, source: 'archive',
        contentType: '', notes, error: 'No Wayback capture found for this URL',
        failure: 'not_found',
      };
    }
    target = snapshot.url;
    archiveTimestamp = snapshot.timestamp;
    archiveOriginal = snapshot.original;
  }

  let response;
  try {
    response = await http.fetch(target);
  } catch (error) {
    const failure = error as FetchError;
    // A dead live URL is the ordinary case the archive exists for, so try it
    // once rather than making the caller ask twice. A policy rejection is not
    // retried: the archive would be a way around the guard.
    if (!input.archived && failure instanceof FetchError && failure.kind !== 'policy') {
      const snapshot = await findSnapshot(http, input.url, input.archivedBefore).catch(() => null);
      if (!snapshot) {
        return {
          ok: false, url: input.url, requestedUrl: input.url, source: 'live',
          contentType: '', notes, error: failure.message,
          failure: classifyFailure(failure), attempts: failure.attempts,
        };
      }
      notes.push(`Live fetch failed (${failure.message}); read the Wayback capture instead.`);
      source = 'archive';
      archiveTimestamp = snapshot.timestamp;
      archiveOriginal = snapshot.original;
      try {
        response = await http.fetch(snapshot.url);
      } catch (archiveError) {
        // Reported here rather than thrown: the transport layer above would
        // flatten this to a bare message and drop the notes explaining that the
        // live read was refused first.
        const archiveFailure = archiveError as FetchError;
        return {
          ok: false, url: snapshot.url, requestedUrl: input.url, source: 'archive',
          contentType: '', notes, error: archiveFailure.message,
          ...(archiveFailure instanceof FetchError
            ? { failure: classifyFailure(archiveFailure), attempts: archiveFailure.attempts }
            : {}),
        };
      }
    } else {
      return {
        ok: false, url: target, requestedUrl: input.url, source,
        contentType: '', notes, error: failure.message,
        ...(failure instanceof FetchError
          ? { failure: classifyFailure(failure), attempts: failure.attempts }
          : {}),
      };
    }
  }

  // A challenge is served as 200 with a short body, so it survives every check
  // above and would be returned as the page. Treat it as the block it is, and
  // reach for the capture the same way a refused fetch does.
  const challenge = source === 'live' ? detectChallenge(response.text) : null;
  if (challenge) {
    const snapshot = await findSnapshot(http, input.url, input.archivedBefore).catch(() => null);
    if (!snapshot) {
      return {
        ok: false, url: response.url, requestedUrl: input.url, source: 'live',
        contentType: response.contentType, notes, failure: 'blocked',
        attempts: 1,
        error: `Anti-bot challenge served instead of the page (matched /${challenge}/)`,
      };
    }
    notes.push(`Live page was an anti-bot challenge (matched /${challenge}/); read the Wayback capture instead.`);
    source = 'archive';
    archiveTimestamp = snapshot.timestamp;
    archiveOriginal = snapshot.original;
    try {
      response = await http.fetch(snapshot.url);
    } catch (error) {
      const failure = error as FetchError;
      return {
        ok: false, url: snapshot.url, requestedUrl: input.url, source: 'archive',
        contentType: '', notes, error: failure.message,
        ...(failure instanceof FetchError
          ? { failure: classifyFailure(failure), attempts: failure.attempts }
          : {}),
      };
    }
  }

  // The capture can be a capture of the wall. The archive index filters for
  // captures it stored with status 200, and an interstitial is served 200, so
  // the newest capture of a permanently walled page is a plausible copy of the
  // block. There is no further fallback, so this is where the read ends.
  if (source === 'archive') {
    const archivedChallenge = detectChallenge(response.text);
    if (archivedChallenge) {
      return {
        ok: false, url: response.url, requestedUrl: input.url, source: 'archive',
        contentType: response.contentType, notes, failure: 'blocked',
        ...(archiveTimestamp ? { archiveTimestamp } : {}),
        error: `The archived capture is itself an anti-bot challenge (matched /${archivedChallenge}/)`,
      };
    }
  }

  const base = {
    ok: true as const,
    url: response.url,
    requestedUrl: input.url,
    source,
    contentType: response.contentType,
    ...(archiveTimestamp ? { archiveTimestamp } : {}),
    // Carried separately from the character cap below: they answer different
    // questions and a caller keys its retry on them differently.
    bodyTruncated: response.truncated,
    redirects: response.redirects,
  };

  if (/^application\/pdf/i.test(response.contentType)) {
    if (response.truncated) {
      return { ...base, ok: false, notes, failure: 'size',
        error: 'PDF exceeded the size cap; a partial PDF cannot be parsed' };
    }
    const { text, pages } = await extractPdfText(new Uint8Array(response.bytes));
    return { ...base, pages, ...cap(text, input.maxChars), notes };
  }

  if (isBinary(response.contentType)) {
    return { ...base, ok: false, notes, failure: 'unsupported',
      error: `Unsupported content type ${response.contentType}` };
  }

  if (response.truncated) {
    notes.push('Response hit the size cap; the document is incomplete and extraction may be partial.');
  }

  const documentUrl = archiveOriginal ?? response.url;

  const article = extractArticle(response.text, documentUrl);
  if (!article) {
    notes.push('Readability found no article body — this is probably an index or application page, not prose.');
    return {
      ...base,
      canonicalUrl: canonicalUrl(response.text, documentUrl),
      title: /<title[^>]*>([\s\S]*?)<\/title>/i.exec(response.text)?.[1]?.trim() ?? null,
      ...cap(stripTags(response.text), input.maxChars),
      notes,
    };
  }

  return {
    ...base,
    canonicalUrl: canonicalUrl(response.text, documentUrl),
    title: article.title,
    byline: article.byline,
    siteName: article.siteName,
    publishedTime: article.publishedTime,
    lang: article.lang,
    excerpt: article.excerpt,
    links: article.links,
    ...cap(article.text, input.maxChars),
    notes,
  };
}

function cap(text: string, maxChars: number): { text: string; chars: number; truncated: boolean } {
  if (text.length <= maxChars) return { text, chars: text.length, truncated: false };
  return { text: text.slice(0, maxChars), chars: maxChars, truncated: true };
}

function stripTags(html: string): string {
  return html
    .replace(/<(script|style|noscript|template)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}
