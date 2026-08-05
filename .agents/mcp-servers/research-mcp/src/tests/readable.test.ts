import { describe, expect, it } from 'vitest';
import { canonicalUrl, extractArticle } from '../core/readable.js';
import { decode, isBinary } from '../core/http-client.js';

const body = 'Sentences long enough to clear the Readability character threshold. '.repeat(12);
const page = (extra = '') => `<!doctype html><html lang="en"><head><title>A Title</title>${extra}</head>
<body><article><h1>A Title</h1><p>${body}</p><p><a href="/next">next</a></p>
<p><img src="fig/one.png"></p></article></body></html>`;

describe('extractArticle', () => {
  it('extracts title and body text', () => {
    const article = extractArticle(page(), 'https://example.com/dir/post.html');
    expect(article).not.toBeNull();
    expect(article?.title).toBe('A Title');
    expect(article?.text).toContain('Readability character threshold');
    expect(article?.length).toBeGreaterThan(100);
  });

  it('returns absolute links resolved against the fetched URL', () => {
    // linkedom leaves baseURI null, so Readability emits the raw relative href
    // unless <base> is injected first — the caller would get "/next", which it
    // cannot follow.
    const article = extractArticle(page(), 'https://example.com/dir/post.html');
    expect(article?.links).toContainEqual({ text: 'next', url: 'https://example.com/next' });
  });

  it('honours a document that already declares a base', () => {
    const article = extractArticle(
      page('<base href="https://cdn.example.org/">'),
      'https://example.com/dir/post.html',
    );
    expect(article?.links).toContainEqual({ text: 'next', url: 'https://cdn.example.org/next' });
  });

  it('drops in-page, javascript and mailto anchors', () => {
    const html = `<html><head></head><body><article><p>${body}</p>
      <a href="#top">top</a><a href="javascript:void(0)">js</a>
      <a href="mailto:x@example.com">mail</a><a href="/keep">keep</a></article></body></html>`;
    const links = extractArticle(html, 'https://example.com/')?.links ?? [];
    expect(links.map((link) => link.url)).toEqual(['https://example.com/keep']);
  });

  it('returns null when there is nothing to extract', () => {
    expect(extractArticle('', 'https://example.com/')).toBeNull();
  });

  it('yields near-empty text for a page that is only navigation', () => {
    // Readability is lenient and still returns a result here rather than null,
    // so the caller distinguishes prose from chrome by length, not by null.
    const article = extractArticle('<html><body><nav>x</nav></body></html>', 'https://example.com/');
    expect(article?.length ?? 0).toBeLessThan(10);
  });

  it('survives a document with no head', () => {
    const article = extractArticle(`<article><p>${body}</p></article>`, 'https://example.com/x');
    expect(article?.text).toContain('Readability');
  });
});

describe('canonicalUrl', () => {
  it('resolves a relative canonical link', () => {
    const html = '<html><head><link rel="canonical" href="/real/page"></head><body></body></html>';
    expect(canonicalUrl(html, 'https://example.com/dir/x')).toBe('https://example.com/real/page');
  });

  it('returns null when absent', () => {
    expect(canonicalUrl('<html></html>', 'https://example.com/')).toBeNull();
  });
});

describe('decode', () => {
  it('uses the charset the server declared', () => {
    const bytes = Buffer.from([0xa9, 0x62, 0x63]); // © b c in latin1
    expect(decode(bytes, 'text/html; charset=iso-8859-1')).toBe('©bc');
  });

  it('falls back to the document meta charset', () => {
    const bytes = Buffer.concat([
      Buffer.from('<html><head><meta charset="iso-8859-1"></head><body>', 'latin1'),
      Buffer.from([0xa9]),
    ]);
    expect(decode(bytes, 'text/html')).toContain('©');
  });

  it('defaults to utf-8 and never throws on a bogus charset', () => {
    expect(decode(Buffer.from('hi', 'utf8'), 'text/html; charset=not-a-charset')).toBe('hi');
  });
});

describe('isBinary', () => {
  it.each(['application/pdf', 'image/png', 'application/octet-stream'])('flags %s', (type) => {
    expect(isBinary(type)).toBe(true);
  });
  it.each(['text/html; charset=utf-8', 'application/json'])('passes %s', (type) => {
    expect(isBinary(type)).toBe(false);
  });
});
