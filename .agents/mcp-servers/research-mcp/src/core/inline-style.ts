/**
 * An inline style as a browser reads it (CSS Syntax Level 3): comments
 * separate tokens, a `;` inside a string or parentheses does not end a
 * declaration, escapes decode, and an `!important` declaration beats a later
 * plain one. Property and value come back lower-cased with spaces collapsed.
 */
export function declarations(style: string): Map<string, string> {
  const result = new Map<string, string>();
  const important = new Set<string>();
  for (const declaration of splitDeclarations(style)) {
    const colon = declaration.indexOf(':');
    if (colon < 0) continue;
    const property = decodeEscapes(declaration.slice(0, colon)).trim().toLowerCase();
    const raw = decodeEscapes(declaration.slice(colon + 1)).trim().toLowerCase().replace(/\s+/g, ' ');
    const isImportant = /!\s*important$/.test(raw);
    if (!property || (important.has(property) && !isImportant)) continue;
    if (isImportant) important.add(property);
    result.set(property, raw.replace(/\s*!\s*important$/, ''));
  }
  return result;
}

function splitDeclarations(style: string): string[] {
  const parts: string[] = [];
  let current = '';
  let quote = '';
  let depth = 0;
  for (let i = 0; i < style.length; i++) {
    const char = style.charAt(i);
    if (char === '\\') {
      current += style.slice(i, i + 2);
      i++;
    } else if (quote) {
      if (char === quote || char === '\n') quote = '';
      current += char;
    } else if (char === '/' && style.charAt(i + 1) === '*') {
      const end = style.indexOf('*/', i + 2);
      i = end < 0 ? style.length : end + 1;
      current += ' ';
    } else if (char === ';' && depth === 0) {
      parts.push(current);
      current = '';
    } else {
      if (char === '"' || char === "'") quote = char;
      else if (char === '(') depth++;
      else if (char === ')') depth = Math.max(0, depth - 1);
      current += char;
    }
  }
  parts.push(current);
  return parts;
}

function decodeEscapes(text: string): string {
  return text.replace(/\\(?:([0-9a-fA-F]{1,6})[ \t\n\r\f]?|([^]))/g, (_match, hex?: string, literal?: string) => {
    if (hex === undefined) return literal ?? '';
    const code = parseInt(hex, 16);
    const valid = code > 0 && code <= 0x10ffff && (code < 0xd800 || code > 0xdfff);
    return valid ? String.fromCodePoint(code) : '\u{FFFD}';
  });
}
