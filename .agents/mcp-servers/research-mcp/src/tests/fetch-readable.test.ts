import { describe, expect, it } from 'vitest';
import type { Fetcher, FetchResult } from '../core/http-client.js';
import { handleFetchReadable } from '../mcp/tools/fetch-readable.tool.js';

const ORIGINAL = 'https://builtin.com/jobs/remote/dev-engineering';
const TIMESTAMP = '20260422020409';
const CAPTURE = `https://web.archive.org/web/${TIMESTAMP}id_/${ORIGINAL}`;

/**
 * A capture whose links are site-root relative, which is how a real job board
 * paginates. Resolving these against the archive host is the defect under test.
 */
const CAPTURED_HTML = `<!doctype html><html><head>
  <title>Remote engineering jobs</title>
  <link rel="canonical" href="/jobs/remote/dev-engineering">
</head><body><article>
  <p>Two hundred words of listing prose so Readability keeps this body rather
  than discarding it as chrome. Senior Backend Engineer, remote, United States.
  The role covers data collection services, API design and database work, and
  the team is hiring across several levels. Compensation is published per
  posting. ${'Further listing detail follows in the capture. '.repeat(12)}</p>
  <a href="/jobs/remote/dev-engineering?page=2">Page 2</a>
  <a href="https://example.com/external">External</a>
</article></body></html>`;

const CDX_ROWS = JSON.stringify([
  ['timestamp', 'original', 'statuscode'],
  [TIMESTAMP, ORIGINAL, '200'],
]);

function result(url: string, text: string, contentType = 'text/html'): FetchResult {
  return {
    url,
    status: 200,
    contentType,
    text,
    bytes: Buffer.from(text),
    truncated: false,
    redirects: [],
  };
}

/** Answers the archive index, then the capture itself. */
class ArchiveFetcher implements Fetcher {
  readonly requested: string[] = [];

  async fetch(url: string): Promise<FetchResult> {
    this.requested.push(url);
    if (url.startsWith('https://web.archive.org/cdx/')) {
      return result(url, CDX_ROWS, 'application/json');
    }
    if (url === CAPTURE) return result(CAPTURE, CAPTURED_HTML);
    throw new Error(`unexpected fetch of ${url}`);
  }
}

describe('fetch_readable on an archived page', () => {
  it('resolves links and the canonical tag against the original site, not the archive', async () => {
    const http = new ArchiveFetcher();
    const out = await handleFetchReadable(
      { url: ORIGINAL, archived: true, maxChars: 120_000 },
      http,
    );

    expect(out.ok).toBe(true);
    expect(out.source).toBe('archive');
    expect(out.archiveTimestamp).toBe(TIMESTAMP);
    expect(out.canonicalUrl).toBe(ORIGINAL);

    const paged = out.links?.find((link) => link.url.includes('page=2'));
    expect(paged?.url).toBe(`${ORIGINAL}?page=2`);
    // The precise regression: the capture is served from web.archive.org, and a
    // root-relative link resolved against that host points nowhere.
    for (const link of out.links ?? []) {
      expect(link.url).not.toContain('web.archive.org');
    }
  });

  it('still reports the archive address it actually read', async () => {
    const http = new ArchiveFetcher();
    const out = await handleFetchReadable(
      { url: ORIGINAL, archived: true, maxChars: 120_000 },
      http,
    );
    expect(out.url).toBe(CAPTURE);
    expect(out.requestedUrl).toBe(ORIGINAL);
  });
});
