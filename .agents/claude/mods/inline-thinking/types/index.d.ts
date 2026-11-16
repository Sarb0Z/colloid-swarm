/**
 * Thinking summaries keyed by the transcript row they are drawn against:
 * `tool:<tool_use_id>` above a tool call, `after-tool:<tool_use_id>` below its
 * result, `after-prompt:<opening words>` below the user's prompt, and
 * `text:<opening words>` above a reply or narration line. Each value lists the
 * summaries in the order the model wrote them.
 */
export type Anchors = Record<string, string[]>

declare module 'claude-code' {
  interface PluginState {
    'inline-thinking': { anchors: Anchors }
  }
}
