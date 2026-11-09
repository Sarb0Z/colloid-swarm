/**
 * Removes page content a reader does not see, before an agent reads it.
 *
 * A page can address the agent reading it in text no visitor sees: a
 * zero-font-size span, a clipped zero-size box, a <template>. Readability drops
 * some hidden markup itself (display:none, [hidden], aria-hidden), but keeps
 * those. Invisible characters are `invisible-chars.ts`'s concern.
 *
 * Only inline style is read: hiding through a stylesheet class needs a CSS
 * engine. Off-screen positioning is left alone on purpose, because that is how
 * pages carry text meant for screen readers.
 */

import { declarations } from './inline-style.js';

/** The DOM subset used here. linkedom's declarations resolve to `any` under this build's libs. */
export interface DomNode {
  readonly nodeType: number;
  readonly nodeName: string;
  readonly parentNode: DomNode | null;
  readonly childNodes: ArrayLike<DomNode>;
  readonly textContent: string | null;
  readonly isConnected: boolean;
  remove(): void;
}

export interface DomElement extends DomNode {
  getAttribute(name: string): string | null;
}

export interface DomDocument {
  readonly documentElement: DomElement;
  readonly body: DomElement | null;
  querySelectorAll(selectors: string): ArrayLike<DomElement>;
}

export interface HiddenElements {
  /** Elements holding text that were removed because inline style made them invisible. */
  readonly removed: number;
  /** Non-whitespace characters those elements held. */
  readonly removedChars: number;
  /** Inline-invisible elements holding text, kept because they held too much of the page to be planted. */
  readonly kept: number;
  /** Share of the page's text, 0 to 1, that the inline-invisible elements held. */
  readonly share: number;
}

const ELEMENT_NODE = 1;
const TEXT_NODE = 3;

/** Containers whose text never renders as page content. */
const NON_CONTENT = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE']);

/**
 * Past this share of the page's text, inline-invisible content is the page's
 * own content waiting for a script to reveal it, such as tab panels collapsed
 * to zero height. Removing it would return a page with its body missing while
 * reporting success.
 */
const MAX_REMOVED_SHARE = 0.25;

const ANIMATION_PROPERTIES = [
  'transform', 'translate', 'scale', 'rotate', 'filter', 'transition', 'animation', 'will-change',
] as const;

/**
 * `absent` renders nothing, the same call Readability already makes.
 * `invisible` renders an element no one can see. `fontless` hides only the text
 * that no descendant resizes: a zero font size on a parent is also how pages
 * close the gaps between inline blocks whose children set their own size.
 */
type Visibility = 'absent' | 'invisible' | 'fontless' | 'shown';

interface Candidate {
  readonly element: DomElement;
  readonly visibility: Visibility;
}

interface Part {
  readonly nodes: readonly DomNode[];
  readonly chars: number;
}

/** Removes everything a reader does not see, for text read straight from the page. */
export function removeHiddenElements(document: DomDocument): HiddenElements {
  return removeElements(document, 'all');
}

/**
 * Removes what Readability would keep: <template> content and inline-invisible
 * content. It leaves `display:none`, `visibility`, `[hidden]` and
 * `aria-hidden` to Readability, which drops them itself; removing them first
 * changes which block it picks as the article (on motion.dev, dropping 140
 * aria-hidden menu duplicates cost 19 characters of the body).
 */
export function removeConcealedElements(document: DomDocument): HiddenElements {
  return removeElements(document, 'concealed');
}

function removeElements(document: DomDocument, scope: 'all' | 'concealed'): HiddenElements {
  const candidates = Array.from(
    document.querySelectorAll('template, [hidden], [aria-hidden], [style]'),
    (element): Candidate => ({ element, visibility: classify(element) }),
  );
  const leftToReadability = new Set<DomNode>();
  for (const { element, visibility } of candidates) {
    if (visibility !== 'absent') continue;
    if (scope === 'all' || element.nodeName === 'TEMPLATE') element.remove();
    else leftToReadability.add(element);
  }
  // An invisible element with no text costs nothing to drop and says nothing
  // to report; only the ones that hold text count.
  const parts = invisibleParts(candidates.filter(({ element }) => !hasAncestorIn(element, leftToReadability)));
  const worded = parts.filter((part) => part.chars > 0).length;
  const total = visibleChars(document.body ?? document.documentElement);
  const hidden = parts.reduce((sum, part) => sum + part.chars, 0);
  const share = total === 0 ? 0 : hidden / total;
  if (share > MAX_REMOVED_SHARE) return { removed: 0, removedChars: 0, kept: worded, share };
  for (const part of parts) {
    for (const node of part.nodes) node.remove();
  }
  return { removed: worded, removedChars: hidden, kept: 0, share };
}

/** The text a reader sees: every text node outside non-content containers, separated as tags separate them. */
export function visibleText(root: DomNode): string {
  const pieces: string[] = [];
  walk(root, (node) => {
    if (node.nodeType === TEXT_NODE) pieces.push(node.textContent ?? '');
    return true;
  });
  return pieces.join(' ').replace(/\s+/g, ' ').trim();
}

function classify(element: DomElement): Visibility {
  if (element.nodeName === 'TEMPLATE') return 'absent';
  const hidden = element.getAttribute('hidden');
  // `until-found` content is collapsed but opens on find-in-page, so it is content.
  if (hidden !== null && hidden.trim().toLowerCase() !== 'until-found') return 'absent';
  if (element.getAttribute('aria-hidden')?.trim().toLowerCase() === 'true') return 'absent';
  const style = element.getAttribute('style');
  return style ? classifyStyle(declarations(style)) : 'shown';
}

function classifyStyle(style: ReadonlyMap<string, string>): Visibility {
  if (style.get('display') === 'none') return 'absent';
  const visibility = style.get('visibility');
  if (visibility === 'hidden' || visibility === 'collapse') return 'absent';
  if (isZero(style.get('font-size'))) return 'fontless';
  // Zero opacity is not read as hidden: animate-on-load pages render visible
  // content at `opacity:0` for a script to fade in (linear.app's hero, 177
  // elements on framer.com), and no inline signal separates that from planted
  // text. An element set up to move is likewise a reveal waiting for its
  // script, such as an accordion animating its height.
  if (ANIMATION_PROPERTIES.some((property) => (style.get(property) ?? 'none') !== 'none')) return 'shown';
  // A zero-size box still paints its children unless it clips them, and it
  // clips at its padding edge, so padding keeps an aspect-ratio box visible.
  const [overflowX, overflowY = overflowX] = (style.get('overflow') ?? 'visible').split(' ');
  const [top = '0', right = top, bottom = top, left = right] = (style.get('padding') ?? '0').split(' ');
  const padded = (side: string, fallback: string) => !isZero(style.get(`padding-${side}`) ?? fallback);
  const closedY = (style.get('overflow-y') ?? overflowY) !== 'visible' && !padded('top', top) && !padded('bottom', bottom);
  const closedX = (style.get('overflow-x') ?? overflowX) !== 'visible' && !padded('left', left) && !padded('right', right);
  if (closedY && (isZero(style.get('height')) || isZero(style.get('max-height')))) return 'invisible';
  if (closedX && (isZero(style.get('width')) || isZero(style.get('max-width')))) return 'invisible';
  return 'shown';
}

/**
 * The inline-invisible content still in the document, with its size in
 * visible characters. An element inside a wholly invisible one goes with it;
 * one inside a zero-font-size element is its own part, since a descendant
 * that gives text a size again stops the outer part above it.
 */
function invisibleParts(candidates: readonly Candidate[]): Part[] {
  const whole = new Set<DomNode>(candidates.filter((c) => c.visibility === 'invisible').map((c) => c.element));
  const marked = new Set<DomNode>(
    candidates.filter((c) => c.visibility === 'invisible' || c.visibility === 'fontless').map((c) => c.element),
  );
  const parts: Part[] = [];
  for (const { element, visibility } of candidates) {
    if (!marked.has(element) || !element.isConnected || hasAncestorIn(element, whole)) continue;
    const nodes = visibility === 'fontless' ? fontlessText(element, marked) : [element];
    parts.push({ nodes, chars: nodes.reduce((sum, node) => sum + visibleChars(node), 0) });
  }
  return parts;
}

/**
 * Text nodes under a zero-font-size element that no descendant gives a size
 * again. Whitespace stays: it is the gap the zero size closes, and removing it
 * would join the words on either side. A marked descendant is its own part.
 */
function fontlessText(root: DomElement, marked: ReadonlySet<DomNode>): DomNode[] {
  const found: DomNode[] = [];
  walk(root, (node) => {
    if (node.nodeType === TEXT_NODE && /\S/.test(node.textContent ?? '')) found.push(node);
    if (node === root || !isElement(node)) return true;
    if (marked.has(node)) return false;
    const size = declarations(node.getAttribute('style') ?? '').get('font-size');
    return size === undefined || !resizes(size);
  });
  return found;
}

const RELATIVE_LENGTH = /(?:\d|\.)(?:%|em|ex|ch|cap|ic|lh)\b|%/;

/** A font size that gives text a size again under a zero-size parent: not zero and not relative to the parent. */
function resizes(size: string): boolean {
  if (isZero(size) || RELATIVE_LENGTH.test(size)) return false;
  return !['inherit', 'unset', 'revert', 'smaller', 'larger'].includes(size);
}

function hasAncestorIn(node: DomNode, set: ReadonlySet<DomNode>): boolean {
  for (let parent = node.parentNode; parent; parent = parent.parentNode) {
    if (set.has(parent)) return true;
  }
  return false;
}

/** Non-whitespace characters of rendered text, so indentation does not weigh in a share. */
function visibleChars(root: DomNode): number {
  let chars = 0;
  walk(root, (node) => {
    if (node.nodeType === TEXT_NODE) chars += (node.textContent ?? '').replace(/\s+/g, '').length;
    return true;
  });
  return chars;
}

/**
 * Depth-first over `root` and its descendants, skipping non-content
 * containers. `visit` returns whether to descend. Iterative, because a page's
 * nesting depth is the page author's choice. linkedom builds `childNodes`
 * afresh on every read, so it is read once per node: read per child, a
 * 20,000-row table takes 13 seconds.
 */
function walk(root: DomNode, visit: (node: DomNode) => boolean): void {
  const stack: DomNode[] = [root];
  for (let node = stack.pop(); node; node = stack.pop()) {
    if (isElement(node) && NON_CONTENT.has(node.nodeName)) continue;
    if (!visit(node)) continue;
    const children = node.childNodes;
    for (let i = children.length - 1; i >= 0; i--) {
      const child = children[i];
      if (child) stack.push(child);
    }
  }
}

function isElement(node: DomNode): node is DomElement {
  return node.nodeType === ELEMENT_NODE;
}

const ZERO = /^[+-]?(?:0+(?:\.0*)?|\.0+)(?:e[+-]?\d+)?(?:[a-z]+|%)?$/;

function isZero(value: string | undefined): boolean {
  return value !== undefined && ZERO.test(value);
}
