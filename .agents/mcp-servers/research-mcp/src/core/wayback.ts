import type { Fetcher } from './http-client.js';

export interface Snapshot {
  /** Fetchable URL for the archived bytes, without the Wayback toolbar. */
  url: string;
  /** Wayback timestamp, YYYYMMDDhhmmss. */
  timestamp: string;
  original: string;
}

/**
 * Resolves the newest successful capture through the CDX index.
 *
 * The simpler `/wayback/available` endpoint answers the same question, but the
 * Internet Archive's own tooling advises against it on latency grounds and it
 * measured ~12s per call; CDX answers in a fraction of that.
 */
export async function findSnapshot(
  http: Fetcher,
  url: string,
  timestamp?: string,
): Promise<Snapshot | null> {
  const query = new URLSearchParams({
    url,
    output: 'json',
    fl: 'timestamp,original,statuscode',
    filter: 'statuscode:200',
    collapse: 'digest',
    limit: '-1', // negative limit walks back from the newest capture
  });
  if (timestamp) query.set('to', timestamp);

  const response = await http.fetch(`https://web.archive.org/cdx/search/cdx?${query.toString()}`);
  const rows: unknown = JSON.parse(response.text || '[]');
  if (!Array.isArray(rows) || rows.length < 2) return null;
  // Row 0 is the field header; the first data row is the capture.
  const row = rows[1];
  if (!Array.isArray(row)) return null;
  const stamp = typeof row[0] === 'string' ? row[0] : null;
  const original = typeof row[1] === 'string' ? row[1] : null;
  if (!stamp || !original) return null;
  // `id_` returns the captured bytes verbatim: no rewritten links, no injected
  // toolbar, so extraction sees the page as it was served.
  return {
    url: `https://web.archive.org/web/${stamp}id_/${original}`,
    timestamp: stamp,
    original,
  };
}
