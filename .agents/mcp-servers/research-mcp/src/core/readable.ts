import { Readability } from '@mozilla/readability';
import { parseHTML } from 'linkedom';

export interface ArticleLink {
  text: string;
  url: string;
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
  const parsed = new Readability(document).parse();
  if (!parsed) return null;
  const text = (parsed.textContent ?? '').replace(/\n{3,}/g, '\n\n').trim();
  return {
    title: parsed.title || null,
    byline: parsed.byline || null,
    siteName: parsed.siteName || null,
    publishedTime: parsed.publishedTime || null,
    lang: parsed.lang || null,
    excerpt: parsed.excerpt || null,
    text,
    links: collectLinks(parsed.content ?? '', url),
    length: text.length,
  };
}

function collectLinks(contentHtml: string, url: string): ArticleLink[] {
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
    links.push({ text: (anchor.textContent ?? '').replace(/\s+/g, ' ').trim(), url: absolute });
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

export async function extractPdfText(bytes: Uint8Array): Promise<{ text: string; pages: number }> {
  const { extractText, getDocumentProxy } = await import('unpdf');
  const document = await getDocumentProxy(bytes);
  const { totalPages, text } = await extractText(document, { mergePages: true });
  return { text: String(text).replace(/\n{3,}/g, '\n\n').trim(), pages: totalPages };
}
