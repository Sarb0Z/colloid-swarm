/** Text with its invisible characters removed, and how many of them looked planted. */
export interface CleanText {
  readonly text: string;
  /** Removed characters that ordinary text has no use for, the signature of a planted payload. */
  readonly suspicious: number;
}

const ZWJ = '\u{200D}';
const ZWNJ = '\u{200C}';
const VS16 = '\u{FE0F}';
const BLACK_FLAG = '\u{1F3F4}';
const CANCEL_TAG = '\u{E007F}';
const IGNORABLE = /\p{Default_Ignorable_Code_Point}/u;
const ANY_INVISIBLE = /[\p{Default_Ignorable_Code_Point}\0-\x08\x0B\x0C\x0E-\x1F\x7F]/u;
const PICTOGRAPHIC = /[\p{Extended_Pictographic}\p{Emoji_Modifier}]/u;
const EMOJI = /\p{Emoji}/u;
const JOINING_LETTER = /[\p{L}\p{M}]/u;
const SPACED_SCRIPT = /[\p{Script=Latin}\p{Script=Greek}\p{Script=Cyrillic}\p{Script=Common}]/u;
const HAN = /\p{Script=Han}/u;
const MONGOLIAN = /\p{Script=Mongolian}/u;

/**
 * The subdivision flags platforms draw: England, Scotland, Wales. Any other
 * tag sequence renders as a plain black flag, so its tag letters are text a
 * reader never sees, however flag-shaped the sequence around them.
 */
const DRAWN_SUBDIVISIONS = new Set(['gbeng', 'gbsct', 'gbwls']);

/**
 * Removes the code points Unicode marks as default-ignorable, which render as
 * nothing, plus C0 controls other than tab and line breaks. A page can spell an
 * instruction in them that a reader never sees and a tokenizer keeps: one
 * study found Anthropic models act on Unicode tag characters
 * (arXiv:2603.00164), and runs of variation selectors carry arbitrary bytes.
 *
 * Some of them carry meaning in context and are kept there: a joiner or
 * non-joiner between letters of a script that joins (Persian, Urdu, Indic), a
 * joiner inside an emoji sequence, a variation selector after the character it
 * selects for, and the tag characters of a drawn subdivision flag.
 */
export function stripInvisible(text: string): CleanText {
  if (!ANY_INVISIBLE.test(text)) return { text, suspicious: 0 };
  const points = Array.from(text);
  const kept = points.map((point, i) => !isInvisible(point) || justified(points, i));
  let suspicious = 0;
  const out: string[] = [];
  points.forEach((point, i) => {
    if (kept[i]) out.push(point);
    else if (isSuspicious(points, kept, i)) suspicious++;
  });
  return { text: out.join(''), suspicious };
}

function isInvisible(point: string): boolean {
  const code = point.codePointAt(0) ?? 0;
  if (code === 0x09 || code === 0x0a || code === 0x0d) return false;
  if (code < 0x20 || code === 0x7f) return true;
  return code >= 0xad && IGNORABLE.test(point);
}

function justified(points: readonly string[], i: number): boolean {
  const point = points[i] ?? '';
  const before = points[i - 1] ?? '';
  const after = points[i + 1] ?? '';
  if (point === ZWJ) return (endsEmoji(points, i - 1) && PICTOGRAPHIC.test(after)) || joins(before, after);
  if (point === ZWNJ) return joins(before, after);
  const code = point.codePointAt(0) ?? 0;
  if (code === 0xfe0e || code === 0xfe0f) return EMOJI.test(before) && !isInvisible(before);
  if (code >= 0xfe00 && code <= 0xfe0d) return (before.codePointAt(0) ?? 0) > 0x7f && !isInvisible(before);
  if (code >= 0xe0100 && code <= 0xe01ef) return HAN.test(before);
  if (code >= 0x180b && code <= 0x180f) return MONGOLIAN.test(before);
  if (code >= 0xe0000 && code <= 0xe007f) return inDrawnFlag(points, i);
  return false;
}

/** The code point at `i` ends an emoji, counting a presentation selector that follows one. */
function endsEmoji(points: readonly string[], i: number): boolean {
  const point = points[i] ?? '';
  if (point === VS16) return PICTOGRAPHIC.test(points[i - 1] ?? '');
  return PICTOGRAPHIC.test(point);
}

/** Both neighbours are visible letters of a script whose words a joiner or non-joiner shapes. */
function joins(before: string, after: string): boolean {
  const letter = (point: string) =>
    !isInvisible(point) && JOINING_LETTER.test(point) && !SPACED_SCRIPT.test(point);
  return letter(before) && letter(after);
}

function inDrawnFlag(points: readonly string[], i: number): boolean {
  const tagLetter = (point: string | undefined) => {
    const code = point?.codePointAt(0) ?? 0;
    return (code >= 0xe0030 && code <= 0xe0039) || (code >= 0xe0061 && code <= 0xe007a);
  };
  if (!tagLetter(points[i]) && points[i] !== CANCEL_TAG) return false;
  let start = i;
  while (tagLetter(points[start - 1])) start--;
  let end = i;
  while (tagLetter(points[end])) end++;
  const spelled = points.slice(start, end).map((point) => String.fromCodePoint((point.codePointAt(0) ?? 0) - 0xe0000));
  return points[start - 1] === BLACK_FLAG && points[end] === CANCEL_TAG && DRAWN_SUBDIVISIONS.has(spelled.join(''));
}

/**
 * A removed code point ordinary text has no use for: a tag character, a
 * joiner or selector with nothing to join or select, or one of a run of
 * removed invisibles. A stray soft hyphen, byte-order mark or zero-width space
 * on its own is noise, not a payload.
 */
function isSuspicious(points: readonly string[], kept: readonly boolean[], i: number): boolean {
  const point = points[i] ?? '';
  const code = point.codePointAt(0) ?? 0;
  if (code >= 0xe0000 && code <= 0xe007f) return true;
  if (point === ZWJ || point === ZWNJ) return true;
  if ((code >= 0xfe00 && code <= 0xfe0f) || (code >= 0xe0100 && code <= 0xe01ef)) return true;
  const removedInvisible = (j: number) => kept[j] === false && isInvisible(points[j] ?? '');
  return removedInvisible(i - 1) || removedInvisible(i + 1);
}
