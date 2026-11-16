import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderElement, ResolveInput } from 'claude-code'

import type { Anchors } from '../types'
import { collect, forget, isTyped, merge, promptKey, sameAnchors, textKey } from './anchors'

// Claude Code draws thinking summaries only in the expanded transcript (Ctrl+O,
// --verbose), and that view expands every tool call too. This mod draws them in
// the collapsed view, between the rows they came between, and draws nothing in
// the expanded one.
//
// Opt-in: the switch is hooks.inline_thinking.enabled in the SESSION
// repository's policy.json and config.json, default off, so a clone of a
// scaffolded repository never changes what its sessions show unasked. An
// operator who wants it everywhere names this folder in CLAUDE_CODE_PLUGIN_DIRS
// and sets INLINE_THINKING_DEFAULT=true in user settings: then it draws unless a
// repository says exactly false, and outside git too. A policy or config file
// that does not parse may be the one saying false, so it turns the mod off.

const empty: Anchors = {}
const anchors = atom({ plugin: 'inline-thinking', key: 'anchors' } as const, empty)

/** What deciding the switch reads from outside the module. */
export type SwitchIO = {
  /** This mod's folder with every link resolved. */
  realPath: () => Promise<string | undefined>
  /** The folder the session runs in. */
  cwd: string
  run: (argv: readonly string[]) => Promise<{ exitCode: number; stdout: string; stderr: string }>
  /** INLINE_THINKING_DEFAULT from the process environment. */
  preset: () => Promise<string | undefined>
  log: (line: string) => void
}

/**
 * The repository whose files decide: a worktree's main checkout; else the
 * folder's own top level (a submodule, a separate git dir); outside git, the
 * folder itself.
 */
async function sessionRepository(io: SwitchIO): Promise<string> {
  const located = await io.run([
    'git', '-C', io.cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir', '--show-toplevel',
  ])
  if (located.exitCode === 0) {
    const [common = '', top = ''] = located.stdout.trim().split('\n')
    return common.endsWith('/.git') ? common.slice(0, -'/.git'.length) : top
  }
  if (located.stderr.includes('not a git repository')) return io.cwd
  throw new Error(`git cannot place ${io.cwd}: ${located.stderr.trim()}`)
}

/**
 * Whether the session's repository turns the mod on, read by the config.py of
 * the checkout this folder belongs to (<checkout>/.agents/claude/mods/
 * inline-thinking, wherever a host link points).
 */
export async function switchIsOn(io: SwitchIO): Promise<boolean> {
  const own = await io.realPath()
  if (own === undefined) throw new Error('cannot resolve the mod folder')
  const checkout = own.split(/[\\/]/).slice(0, -4).join('/')
  const repo = await sessionRepository(io)

  const preset = await io.preset()
  if (preset !== undefined && preset !== 'true' && preset !== 'false') {
    io.log(`INLINE_THINKING_DEFAULT is ${JSON.stringify(preset)}, neither true nor false; treated as false`)
  }
  const fallback = preset === 'true' ? 'true' : 'false'
  const answer = await io.run([
    'python3', `${checkout}/.agents/hooks/lib/config.py`, `${repo}/.agents/config.json`,
    `hooks.inline_thinking.enabled=${fallback}`,
  ])
  const word = answer.stdout.trim()
  if (answer.exitCode !== 0 || (word !== 'yes' && word !== 'no')) {
    throw new Error(`config.py answered ${JSON.stringify(word)} (exit ${answer.exitCode}): ${answer.stderr.trim()}`)
  }
  // config.py writes to stderr only for a file that exists and does not parse.
  if (answer.stderr.trim() !== '') {
    io.log(`off in ${repo}: ${answer.stderr.trim()}`)
    return false
  }
  return word === 'yes'
}

function hostSwitch($: EngineInterface, cwd: string): SwitchIO {
  return {
    realPath: async () => (await $.fs.stat($.plugin.root, { resolve: true })).realPath,
    cwd,
    // git's "not a git repository" is matched in English.
    run: argv => $.process.run([...argv], { env: { LC_ALL: 'C' } }),
    preset: () => $.env.get('INLINE_THINKING_DEFAULT'),
    log: line => $.ui.log(`${$.plugin.name}: ${line}`),
  }
}

// Read on first use, once per folder the session runs in (/cd and a worktree
// move it). session.end clears them, since /clear fires no session.start.
const switches = new Map<string, Promise<boolean>>()

async function isOn($: EngineInterface): Promise<boolean> {
  const cwd = await $.session.cwd()
  const known = switches.get(cwd)
  if (known !== undefined) return known
  const decided = switchIsOn(hostSwitch($, cwd))
  switches.set(cwd, decided)
  return decided
}

// A session's first failure shows in the transcript; the rest go to the debug
// log alone, so a broken switch does not add a line after every tool call.
let reported = false
let kindReported = false

function report($: EngineInterface, line: string): void {
  $.ui.log(`${$.plugin.name}: ${line}`, reported ? { to: 'debug' } : undefined)
  reported = true
}

// One read at a time: a tool call or a turn's end during one asks for one
// more, which reads the conversation as it then stands. Reading never holds
// up a tool call or a turn: the redraw follows the state write.
// debt: inline-thinking-full-reads
let reading = false
let readAgain = false

function refreshInBackground($: EngineInterface): void {
  if (reading) {
    readAgain = true
    return
  }
  reading = true
  drain($).catch((error: unknown) => report($, `thinking summaries were not refreshed: ${String(error)}`))
}

async function drain($: EngineInterface): Promise<void> {
  try {
    do {
      readAgain = false
      await refresh($)
    } while (readAgain)
  } finally {
    reading = false
  }
}

async function refresh($: EngineInterface): Promise<void> {
  // Only the terminal draws summaries; a -p run reads nothing.
  if (!(await $.session.surfaces()).includes('terminal')) return
  if (!(await isOn($))) return
  const collected = collect(await $.session.messages({ as: 'api' }))
  if (collected.unknownKind !== undefined && !kindReported) {
    kindReported = true
    $.ui.log(
      `${$.plugin.name}: a thinking block's signature names the kind ${JSON.stringify(collected.unknownKind)}; ` +
        'it draws as a thinking summary',
      { to: 'debug' },
    )
  }
  const current = await read($, anchors)
  if (sameAnchors(current, merge(current, collected))) return
  await update($, anchors, previous => merge(previous, collected))
}

async function forgetShared($: EngineInterface, keys: readonly string[]): Promise<void> {
  if (keys.length === 0) return
  const current = await read($, anchors)
  if (!keys.some(key => current[key] !== undefined)) return
  await update($, anchors, previous => forget(previous, keys))
}

function draw(
  $: EngineInterface,
  e: ResolveInput,
  above: readonly string[],
  row: RenderElement,
  below: readonly string[],
): RenderElement {
  const { Box, Text } = $.ui.resolve(e)
  // Drawn as Claude Code draws thinking in the expanded view: an italic marker,
  // then dim text whose wrapped lines stay indented under it.
  const summary = (text: string) => (
    <Box marginTop={1} flexDirection="row">
      <Text dimColor italic>
        ∴{' '}
      </Text>
      <Box flexShrink={1}>
        <Text dimColor>{text}</Text>
      </Box>
    </Box>
  )
  return (
    <Box flexDirection="column">
      {above.map(summary)}
      {row}
      {below.map(summary)}
    </Box>
  )
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    refreshInBackground($)
    return started
  })

  // The next conversation starts with no summaries and reads its switch afresh.
  on('session.end', async ($, e, next) => {
    switches.clear()
    reported = false
    await update($, anchors, () => empty)
    return next(e)
  })

  // A prompt that repeats an earlier one ("yes") makes their key name two
  // rows: forget it before the new row draws the old row's summary. A reply
  // that repeats one draws the old summary until the next read, at its tool
  // call or the turn's end: session.append, which would catch it, runs inside
  // Claude Code's own security plugin first on a machine with managed
  // settings, and that plugin passes the event on past user plugins.
  on('prompt.submit', async ($, e, next) => {
    if (e.command === undefined && e.isMeta !== true && isTyped(e.text)) await forgetShared($, [promptKey(e.text)])
    return next(e)
  })

  // The assistant message holding a call is in the transcript once the call
  // runs, so the summary before it appears while the call is still running.
  on('tool.call', ($, e, next) => {
    if (e.agentId === undefined) refreshInBackground($)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const completed = await next(e)
    if (e.agentId === undefined) refreshInBackground($)
    return completed
  })

  // Expanded rows (Ctrl+O, --verbose) already show thinking: pass them on.
  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.isExpanded !== false) return next(e)
    const above = (await read($, anchors))[`tool:${e.props.tool_use_id}`]
    if (above === undefined) return next(e)
    return draw($, e, above, await next(e), [])
  })

  // A standalone call's result is its own row, under the call's.
  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.isExpanded !== false) return next(e)
    const below = (await read($, anchors))[`after-tool:${e.props.tool_use_id}`]
    if (below === undefined) return next(e)
    return draw($, e, [], await next(e), below)
  })

  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.isExpanded) return next(e)
    const known = await read($, anchors)
    const ids = e.props.calls.flatMap(call => (call.tool_use_id === undefined ? [] : [call.tool_use_id]))
    const above = ids.flatMap(id => known[`tool:${id}`] ?? [])
    const below = ids.flatMap(id => known[`after-tool:${id}`] ?? [])
    if (above.length === 0 && below.length === 0) return next(e)
    return draw($, e, above, await next(e), below)
  })

  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.isExpanded) return next(e)
    const below = (await read($, anchors))[promptKey(e.props.text)]
    if (below === undefined) return next(e)
    return draw($, e, [], await next(e), below)
  })

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    const above = (await read($, anchors))[textKey(e.props.text)]
    if (above === undefined) return next(e)
    return draw($, e, above, await next(e), [])
  })
}
