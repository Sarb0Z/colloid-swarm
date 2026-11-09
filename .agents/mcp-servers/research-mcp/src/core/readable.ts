import { Readability } from '@mozilla/readability';
import { parseHTML } from 'linkedom';
import { type HiddenElements, removeConcealedElements, removeHiddenElements, visibleText } from './hidden.js';
import { stripInvisible } from './invisible-chars.js';

export interface ArticleLink {
  text: string;
  url: string;
}

/** What was removed before the text was returned, so the caller can say so. */
export interface HiddenReport {
  readonly elements: HiddenElements;
  /** Invisible characters removed that ordinary text has no use for. */
  readonly suspiciousChars: number;
}

/** A page Readability found no article in: its title and all of its visible text. */
export interface PageText {
  title: string | null;
  text: string;
  hidden: HiddenReport;
}

export interface Article {
  title: string | null;
  byline: string | null;
  siteName: string | null;
  publishedTime: string | null;
  lang: string | null;
  excerpt: string | null;
  text: string;
  /**
   * Absolute links from the article body. Following a citation is the research
   * loop; text alone dead-ends it.
   */
  links: readonly ArticleLink[];
  /** Characters of extracted text. The caller budgets tokens against this. */
  length: number;
  hidden: HiddenReport;
}

/** Links returned per article. Enough to carry a reference list, not a sitemap. */
const MAX_LINKS = 100;

/**
 * linkedom exposes no way to set a document's URL, and Readability resolves
 * every link against `document.baseURI` — which is null without one. Injecting
 * `<base href>` before parsing is the only hook, and skipping it silently ships
 * relative hrefs the caller cannot follow.
 */
function withBase(html: string, url: string): string {
  const tag = `<base href="${url.replace(/&/g, '&amp;').replace(/"/g, '&quot;')}">`;
  if (/<base\b/i.test(html)) return html;
  if (/<head[^>]*>/i.test(html)) return html.replace(/<head[^>]*>/i, (head) => `${head}${tag}`);
  if (/<html[^>]*>/i.test(html)) return html.replace(/<html[^>]*>/i, (open) => `${open}<head>${tag}</head>`);
  // A bare fragment must be wrapped in full: linkedom does not synthesise a
  // <body> around one, and Readability only ever looks inside <body>.
  return `<html><head>${tag}</head><body>${html}</body></html>`;
}

export function extractArticle(html: string, url: string): Article | null {
  const { document } = parseHTML(withBase(html, url));
  const elements = removeConcealedElements(document);
  const parsed = new Readability(document).parse();
  if (!parsed) return null;
  let suspiciousChars = 0;
  // Every string the caller receives goes through here, the metadata included:
  // a title or byline can carry an invisible payload as well as the body.
  const clean = (value: string | null | undefined): string | null => {
    if (!value) return null;
    const result = stripInvisible(value);
    suspiciousChars += result.suspicious;
    return result.text || null;
  };
  const text = (clean(parsed.textContent) ?? '').replace(/\n{3,}/g, '\n\n').trim();
  return {
    title: clean(parsed.title),
    byline: clean(parsed.byline),
    siteName: clean(parsed.siteName),
    publishedTime: clean(parsed.publishedTime),
    lang: clean(parsed.lang),
    excerpt: clean(parsed.excerpt),
    text,
    links: collectLinks(parsed.content ?? '', url, (value) => clean(value) ?? ''),
    length: text.length,
    hidden: { elements, suspiciousChars },
  };
}

/**
 * Text for a page Readability rejects. Readability changes the document it is
 * given, so this parses again rather than reusing that one.
 */
export function extractPageText(html: string, url: string): PageText {
  const { document } = parseHTML(withBase(html, url));
  const elements = removeHiddenElements(document);
  const title = stripInvisible((document.title ?? '').trim());
  const body = stripInvisible(visibleText(document.body ?? document.documentElement));
  return {
    title: title.text || null,
    // The title leads the text, as it does in the page source.
    text: [title.text, body.text].filter(Boolean).join(' '),
    hidden: { elements, suspiciousChars: title.suspicious + body.suspicious },
  };
}

function collectLinks(contentHtml: string, url: string, clean: (text: string) => string): ArticleLink[] {
  const { document } = parseHTML(`<html><body>${contentHtml}</body></html>`);
  const page = safeUrl(url);
  const seen = new Set<string>();
  const links: ArticleLink[] = [];
  for (const anchor of document.querySelectorAll('a[href]')) {
    const href = anchor.getAttribute('href');
    if (!href || /^(javascript|mailto|data|tel):/i.test(href)) continue;
    let resolved: URL;
    try {
      // Readability resolves hrefs against baseURI, which withBase() supplies;
      // resolving again here is what makes a document lacking <base> safe too.
      resolved = new URL(href, url);
    } catch {
      continue;
    }
    // Readability hands anchors over already absolute, so an in-page link
    // reads as "https://host/page#top". Recognising it means comparing against
    // the page URL; a leading-'#' test never matches here.
    if (resolved.hash && page && stripHash(resolved) === page) continue;
    const absolute = resolved.toString();
    if (seen.has(absolute)) continue;
    seen.add(absolute);
    links.push({ text: clean((anchor.textContent ?? '').replace(/\s+/g, ' ').trim()), url: absolute });
    if (links.length >= MAX_LINKS) break;
  }
  return links;
}

/** Canonical URL as the document declares it, resolved against the fetched URL. */
export function canonicalUrl(html: string, url: string): string | null {
  const href = /<link[^>]+rel=["']?canonical["']?[^>]*>/i
    .exec(html)?.[0]
    ?.match(/href=["']([^"']+)["']/i)?.[1];
  if (!href) return null;
  try {
    return new URL(href, url).toString();
  } catch {
    return null;
  }
}

function stripHash(url: URL): string {
  const copy = new URL(url.toString());
  copy.hash = '';
  return copy.toString();
}

function safeUrl(raw: string): string | null {
  try {
    return stripHash(new URL(raw));
  } catch {
    return null;
  }
}

export async function extractPdfText(
  bytes: Uint8Array,
): Promise<{ text: string; pages: number; suspiciousChars: number }> {
  const { extractText, getDocumentProxy } = await import('unpdf');
  const document = await getDocumentProxy(bytes);
  const { totalPages, text } = await extractText(document, { mergePages: true });
  const cleaned = stripInvisible(String(text));
  return {
    text: cleaned.text.replace(/\n{3,}/g, '\n\n').trim(),
    pages: totalPages,
    suspiciousChars: cleaned.suspicious,
  };
}
