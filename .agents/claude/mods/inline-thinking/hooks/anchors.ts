import type { Anchors } from '../types'

// Which row each thinking summary draws at, read from the conversation as the
// Messages API carries it. Pure: the hooks module reads the conversation and
// keeps the result.

// A long session keeps the newest anchors only, so the state stays small.
const MAX_ANCHORS = 400
const MAX_SUMMARY_CHARS = 4000
const TEXT_KEY_CHARS = 160

export type Block = { type: string; [field: string]: unknown }
export type ApiMessage = { role: 'user' | 'assistant'; content: readonly Block[] }

function opening(text: string): string {
  // Cut before collapsing whitespace: a reply can run to megabytes.
  return text.slice(0, TEXT_KEY_CHARS * 4).replace(/\s+/g, ' ').trim().slice(0, TEXT_KEY_CHARS)
}

/** Drawn above a reply or narration line. */
export function textKey(text: string): string {
  return `text:${opening(text)}`
}

/** Drawn below the user's prompt row. */
export function promptKey(text: string): string {
  return `after-prompt:${opening(text)}`
}

/**
 * Whether a user message's text is the person's own. The engine wraps what it
 * adds beside a prompt (a reminder, a task notification) in a tag, so text
 * opening with `<` is the engine's.
 */
export function isTyped(text: string): boolean {
  return text.trim() !== '' && !text.trimStart().startsWith('<')
}

/**
 * The blocks of a user message the person typed, which the prompt row shows.
 * A slash command's message opens with `<command-name>` and its expansion
 * follows untagged, so a message holding one has no typed block. A prompt with
 * none (an image alone, a command) leaves its summaries to the next row.
 */
export function typedBlocks(content: readonly Block[]): string[] {
  const texts = content.flatMap(block => (block.type === 'text' && typeof block.text === 'string' ? [block.text] : []))
  const isCommand = texts.some(text => /^\s*<command-(name|message)>/.test(text))
  return isCommand ? [] : texts.filter(isTyped)
}

// Claude Code tells a narration block (the dim "· summary" line it always
// draws) from a thinking summary by the kind a thinking block's signature
// carries: base64 protobuf, field 2 → field 1 → field 8, "narration" or
// "thinking". The decoder mirrors the CLI's own (2.1.325).
const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function base64Bytes(text: string): Uint8Array | undefined {
  const out: number[] = []
  let bits = 0
  let value = 0
  for (const ch of text.replace(/=+$/, '')) {
    const digit = B64.indexOf(ch)
    if (digit < 0) return undefined
    value = ((value << 6) | digit) & 0xffffff
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out.push((value >> bits) & 0xff)
    }
  }
  return Uint8Array.from(out)
}

function varint(bytes: Uint8Array, at: number): [number, number] | undefined {
  let value = 0
  let scale = 1
  for (let i = at; i < bytes.length; i++) {
    const byte = bytes[i]
    if (byte === undefined) return undefined
    value += (byte & 0x7f) * scale
    scale *= 128
    if (byte < 0x80) return [value, i + 1]
  }
  return undefined
}

function field(bytes: Uint8Array, wanted: number): Uint8Array | undefined {
  let found: Uint8Array | undefined
  let at = 0
  while (at < bytes.length) {
    const key = varint(bytes, at)
    if (key === undefined) return undefined
    const [tag, next] = key
    const wire = tag % 8
    at = next
    if (wire === 0) {
      const skipped = varint(bytes, at)
      if (skipped === undefined) return undefined
      at = skipped[1]
    } else if (wire === 1) {
      at += 8
    } else if (wire === 5) {
      at += 4
    } else if (wire === 2) {
      const length = varint(bytes, at)
      if (length === undefined) return undefined
      const [size, start] = length
      if (Math.floor(tag / 8) === wanted) found = bytes.subarray(start, start + size)
      at = start + size
    } else {
      return undefined
    }
  }
  return found
}

export function signatureKind(signature: unknown): string | undefined {
  if (typeof signature !== 'string' || signature === '') return undefined
  const bytes = base64Bytes(signature)
  if (bytes === undefined) return undefined
  const outer = field(bytes, 2)
  const inner = outer && field(outer, 1)
  const kind = inner && field(inner, 8)
  return kind ? String.fromCharCode(...kind) : undefined
}

function clipped(text: string): string {
  return text.length > MAX_SUMMARY_CHARS ? `${text.slice(0, MAX_SUMMARY_CHARS - 1)}…` : text
}

export type Collected = {
  /** Summaries by the key of the row they draw at; a key two rows share is left out. */
  anchors: Anchors
  /** Every row key the conversation holds, whether a summary draws there or not. */
  keys: ReadonlySet<string>
  /** The first thinking block whose signature names no kind this mod knows. */
  unknownKind: string | undefined
}

/**
 * Walks the conversation and keys each run of thinking summaries to a row
 * whose props say whether the view is expanded, since only an expanded view
 * shows thinking by itself:
 *
 * - above the tool call that follows it (`tool:<id>`);
 * - else below the row before it: a tool call's result (`after-tool:<id>`) or
 *   the user's prompt (`after-prompt:<opening words>`);
 * - else above the next reply or narration line (`text:<opening words>`). A
 *   reply row cannot tell the views apart, so this last case also shows in the
 *   expanded view, beside Claude Code's own copy.
 *
 * Rows are known by their opening words, so a summary at a key two rows share
 * ("yes", "Done.") could be either's, and draws at neither. A prompt drops
 * summaries that nothing followed.
 */
export function collect(messages: readonly ApiMessage[]): Collected {
  const found: Anchors = {}
  const rows = new Map<string, number>()
  let unknownKind: string | undefined
  let pending: string[] = []
  // The keys that draw below the previous row; empty when it was a reply.
  let below: string[] = []
  const row = (key: string) => rows.set(key, (rows.get(key) ?? 0) + 1)
  const place = (aboveKey: string, isToolRow: boolean) => {
    if (pending.length === 0) return
    for (const key of isToolRow || below.length === 0 ? [aboveKey] : below) {
      found[key] = [...(found[key] ?? []), ...pending]
    }
    pending = []
  }

  for (const message of messages) {
    if (message.role === 'user') {
      if (message.content.some(block => block.type === 'tool_result')) continue
      pending = []
      below = typedBlocks(message.content).map(promptKey)
      below.forEach(row)
      continue
    }
    for (const block of message.content) {
      if (block.type === 'thinking') {
        const text = typeof block.thinking === 'string' ? block.thinking.trim() : ''
        if (text === '') continue
        const kind = signatureKind(block.signature)
        if (kind === 'narration') {
          const key = textKey(text)
          row(key)
          place(key, false)
          below = []
          continue
        }
        if (kind !== 'thinking') unknownKind ??= kind ?? 'none'
        pending.push(clipped(text))
      } else if (block.type === 'tool_use' && typeof block.id === 'string') {
        row(`tool:${block.id}`)
        row(`after-tool:${block.id}`)
        place(`tool:${block.id}`, true)
        below = [`after-tool:${block.id}`]
      } else if (block.type === 'text' && typeof block.text === 'string' && block.text.trim() !== '') {
        const key = textKey(block.text)
        row(key)
        place(key, false)
        below = []
      }
    }
  }

  for (const [key, count] of rows) {
    if (count > 1) delete found[key]
  }
  return { anchors: found, keys: new Set(rows.keys()), unknownKind }
}

/**
 * The state after a read. The conversation decides every key it holds; a key
 * only the state holds (compacted away) stays, and the newest MAX_ANCHORS of
 * the whole stay, the conversation's own last.
 */
export function merge(current: Anchors, collected: Collected): Anchors {
  const entries = [
    ...Object.entries(current).filter(([key]) => !collected.keys.has(key)),
    ...Object.entries(collected.anchors),
  ]
  return Object.fromEntries(entries.slice(-MAX_ANCHORS))
}

/** The state less the given keys: a row about to be drawn shares them, so each now names two rows. */
export function forget(current: Anchors, keys: readonly string[]): Anchors {
  return Object.fromEntries(Object.entries(current).filter(([key]) => !keys.includes(key)))
}

export function sameAnchors(a: Anchors, b: Anchors): boolean {
  const entries = Object.entries(a)
  if (entries.length !== Object.keys(b).length) return false
  return entries.every(([key, x]) => {
    const y = b[key]
    return y !== undefined && x.length === y.length && x.every((text, i) => text === y[i])
  })
}
