import { describe, expect, it } from 'vitest';
import { parseHTML } from 'linkedom';
import { removeConcealedElements, removeHiddenElements, visibleText } from '../core/hidden.js';
import { declarations } from '../core/inline-style.js';

const prose = 'Visible prose long enough to be the bulk of the page, as real articles are. '.repeat(20);

function clean(body: string, remove = removeHiddenElements) {
  const { document } = parseHTML(`<html><head><title>T</title></head><body>${body}</body></html>`);
  const report = remove(document);
  return { report, text: visibleText(document.body) };
}

describe('removeHiddenElements', () => {
  it.each([
    ['display:none', '<p style="display:none">PLANTED</p>'],
    ['visibility:hidden', '<p style="visibility: hidden">PLANTED</p>'],
    ['visibility:collapse', '<p style="visibility:collapse">PLANTED</p>'],
    ['the hidden attribute', '<p hidden>PLANTED</p>'],
    ['aria-hidden', '<span aria-hidden="true">PLANTED</span>'],
    ['template content', '<template>PLANTED</template>'],
    ['a clipped zero-height box', '<div style="height:0;overflow:hidden">PLANTED</div>'],
    ['a clipped zero max-height in percent', '<div style="max-height: 0%; overflow: hidden auto">PLANTED</div>'],
    ['a clipped zero-width box', '<div style="width:0px; overflow-x: clip">PLANTED</div>'],
    ['a zero font size', '<span style="font-size:0">PLANTED</span>'],
    ['an important declaration a later one cannot override', '<p style="display:none !important; display:block">PLANTED</p>'],
    ['an escaped value', '<p style="display: \\6e one">PLANTED</p>'],
    ['upper-case CSS', '<p style="DISPLAY : NONE">PLANTED</p>'],
  ])('removes text hidden by %s', (_name, markup) => {
    expect(clean(`<p>${prose}</p>${markup}`).text).not.toContain('PLANTED');
  });

  it.each([
    // linear.app's hero, 2026-11-09: `initial={{ opacity: 0 }}` rendered on the server.
    ['zero opacity, which animate-on-load pages start from', '<div style="opacity:0">SHOWN</div>'],
    ['a zero line height', '<p style="line-height:0">SHOWN</p>'],
    ['a zero-height box that paints its overflow', '<div style="height:0">SHOWN</div>'],
    ['a padded zero-height box, the aspect-ratio pattern', '<div style="height:0;padding-bottom:56%;overflow:hidden">SHOWN</div>'],
    ['a comment splitting a keyword', '<p style="display: no/**/ne">SHOWN</p>'],
    ['a keyword inside a string', '<p style="font-family:\'a;display:none\'">SHOWN</p>'],
    ['hidden=until-found, which opens on find-in-page', '<p hidden="until-found">SHOWN</p>'],
    ['off-screen positioning, the screen-reader pattern', '<span style="position:absolute;left:-9999px">SHOWN</span>'],
    // motion.dev and linear.app, 2026-11-09: reveal-on-scroll sections.
    ['an element set up to move', '<div style="opacity:0;filter:blur(2px);transform:translateY(24px)">SHOWN</div>'],
    ['a collapsed box that animates its height', '<div style="max-height:0;overflow:hidden;transition:max-height .3s">SHOWN</div>'],
  ])('keeps text shown despite %s', (_name, markup) => {
    expect(clean(`<p>${prose}</p>${markup}`).text).toContain('SHOWN');
  });

  it('keeps children that set an absolute size under a zero-font-size parent', () => {
    const { text } = clean(`<p>${prose}</p><div style="font-size:0">GAP<span style="font-size:16px">SHOWN</span>` +
      '<span style="font-size:1em">EM</span><span style="font-size:2ex">EX</span>' +
      '<span style="font-size:calc(1em + 0px)">CALC</span></div>');
    expect(text).toContain('SHOWN');
    for (const hidden of ['GAP', 'EM', 'EX', 'CALC']) expect(text).not.toContain(hidden);
  });

  it('leaves the inline-block gap trick alone', () => {
    const { report, text } = clean(`<p>${prose}</p><ul style="font-size:0"><li style="font-size:14px">Alpha</li> ` +
      '<li style="font-size:14px">Beta</li></ul>');
    expect(text).toContain('Alpha Beta');
    expect(report).toMatchObject({ removed: 0, removedChars: 0 });
  });

  it('removes a box hidden beneath a size reset under a zero-font-size parent', () => {
    const { text } = clean(`<p>${prose}</p><div style="font-size:0"><span style="font-size:16px">SHOWN` +
      '<span style="height:0;overflow:hidden">PLANTED</span></span></div>');
    expect(text).toContain('SHOWN');
    expect(text).not.toContain('PLANTED');
  });

  it('removes a small planted block and reports it', () => {
    const { report, text } = clean(`<p>${prose}</p><span style="font-size:0">PLANTED</span>`);
    expect(text).not.toContain('PLANTED');
    expect(report).toMatchObject({ removed: 1, removedChars: 'PLANTED'.length, kept: 0 });
  });

  it('counts only invisible elements that held text', () => {
    // framer.com carried dozens of inline-invisible elements, most of them empty.
    const { report } = clean(`<p>${prose}</p><div style="height:0;overflow:hidden"></div><span style="font-size:0"> </span>`);
    expect(report).toMatchObject({ removed: 0, removedChars: 0 });
  });

  it('keeps a page whose content sits in collapsed panels a script opens', () => {
    const sections = Array.from({ length: 4 }, (_, i) =>
      `<section style="height:0;overflow:hidden">SECTION${i} ${prose}</section>`).join('');
    const { report, text } = clean(`<nav>Home About</nav>${sections}`);
    expect(text).toContain('SECTION3');
    expect(report.kept).toBe(4);
    expect(report.share).toBeGreaterThan(0.9);
  });

  it('counts a nested invisible element once', () => {
    const { report } = clean(`<p>${prose}</p><div style="width:0;overflow:clip"><span style="font-size:0">PLANTED</span></div>`);
    expect(report.removed).toBe(1);
  });

  it('reads a page with one very wide element in linear time', () => {
    const rows = '<tr><td>cell</td></tr>'.repeat(20_000);
    const started = performance.now();
    const { text } = clean(`<table><tbody>${rows}</tbody></table>`);
    expect(text.length).toBeGreaterThan(20_000 * 4);
    expect(performance.now() - started).toBeLessThan(3_000);
  });
});

describe('removeConcealedElements', () => {
  it('leaves what Readability drops itself, and removes what it keeps', () => {
    const { text } = clean(`<p>${prose}</p><span aria-hidden="true">ARIA</span><p hidden>ATTR</p>` +
      '<template>TEMPLATE</template><span style="font-size:0">FONT</span>', removeConcealedElements);
    expect(text).toContain('ARIA');
    expect(text).toContain('ATTR');
    expect(text).not.toContain('TEMPLATE');
    expect(text).not.toContain('FONT');
  });
});

describe('declarations', () => {
  it('does not end a declaration at a semicolon inside parentheses', () => {
    const style = declarations('background:url(a;b.png); opacity: 0');
    expect(style.get('opacity')).toBe('0');
    expect(style.get('background')).toBe('url(a;b.png)');
  });
});

describe('visibleText', () => {
  it('separates text as tags separate it and skips scripts', () => {
    const { document } = parseHTML('<html><body><ul><li>Home</li><li>About</li></ul><script>var x</script></body></html>');
    expect(visibleText(document.body)).toBe('Home About');
  });
});
