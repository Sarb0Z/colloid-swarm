import type { EngineInterface, Register, RenderElement, ResolveInput } from 'claude-code'

import { DIM, FG, GREEN, RED, YEL, merge, parseGit, stripRows } from './strip'
import type { Git, Profile, Run } from './strip'
import { NEW_TASK, afterBash, afterEdit, afterTurn, callersText, elapsed, markdown, parseCallers, taskCost, usd } from './task'
import type { Task } from './task'

// The band above the prompt: the status strip's rows, drawn from the copy of
// Claude Code's status JSON that .agents/claude/statusline.sh (the relay)
// leaves in a per-user folder, plus a row of this task's own state.
//
// The two meet at ${TMPDIR:-/tmp}/colloid-status-$USER/: the band writes
// <session>.on, and while it stands the relay writes <session>.json and prints
// nothing; without it the person's own status line draws. The marker is
// written first, at session.start and at a draw that sees a new id (/clear goes
// on under one with no session.start), before any process runs, so the relay's
// first run is already silent. A new id starts the task over.
//
// Opening a session (the switch, git, the readouts) runs outside the render
// hook: a draw never waits on a process, and draws nothing of its own until
// the opening finished.
//
// Cost while idle: one in-process stat of the relay file every 2 s, and no
// process. git and readout.py run at the opening, at a prompt, after a Bash,
// Edit or Write, and when the relay file changes, at most once per 5 s unless
// it names another folder; the relay changes only while the engine draws.
// removed-callers.py runs after a turn that edited Python files.
//
// The switch is hooks.status_band.enabled (default true) in the session
// repository's policy.json and config.json, read by this checkout's config.py.

type Json = Record<string, unknown>
type Answer = { exitCode: number; stdout: string; stderr: string }

const ID = /^[A-Za-z0-9_-]+$/
const POLL_MS = 2000
const GIT_EVERY_MS = 5000
const READER_FAILED = 'readouts: reader failed'

type Session = {
  readonly id: string
  /** The session repository: a worktree's main checkout, else the top level. */
  readonly repo: string
  /** The checkout this mod's folder belongs to, which holds its scripts. */
  readonly checkout: string
  readonly on: boolean
  readonly profile: Profile
  /** The relay folder, or undefined where USER is unset. */
  readonly folder: string | undefined
  relay: { mtimeMs: number; status: Json } | undefined
  fallback: Json | undefined
  git: Git | null
  gitCwd: string | undefined
  /** When git last ran, in $.clock.now() milliseconds. */
  gitAt: number
  readouts: string | null
  task: Task
  view: 'full' | 'line'
  refreshing: boolean
  refreshAgain: boolean
  timer: { cancel: () => void } | undefined
  /** The folder could not be made this user's own: the marker is never written. */
  folderRefused: boolean
}

/** A session id seen, and its opening: under way, done, or failed for good. */
type Opened = {
  readonly id: string
  /** Settles once the marker write was tried. */
  readonly marked: Promise<void>
  session: Session | undefined
}

let current: Opened | undefined
let reported = false

function report($: EngineInterface, line: string): void {
  $.ui.log(`${$.plugin.name}: ${line}`, reported ? { to: 'debug' } : undefined)
  reported = true
}

const run = ($: EngineInterface, argv: readonly string[], init?: { cwd?: string; env?: Record<string, string>; stdin?: string }) =>
  $.process.run([...argv], { ...init, env: { LC_ALL: 'C', ...init?.env } })

/** A worktree's main checkout; else the folder's top level; outside git, the folder. */
async function sessionRepository($: EngineInterface, folder: string): Promise<string> {
  const located = await run($, ['git', '-C', folder, 'rev-parse', '--path-format=absolute', '--git-common-dir', '--show-toplevel'])
  if (located.exitCode === 0) {
    const [common = '', top = ''] = located.stdout.trim().split('\n')
    return common.endsWith('/.git') ? common.slice(0, -'/.git'.length) : top
  }
  if (located.stderr.includes('not a git repository')) return folder
  throw new Error(`git cannot place ${folder}: ${located.stderr.trim()}`)
}

/**
 * hooks.status_band.enabled as config.py answers it. config.py falls back to
 * the default for a file that does not parse and says so on stderr: that is
 * reported, and the answer stands.
 */
async function switchIsOn($: EngineInterface, checkout: string, repo: string): Promise<boolean> {
  const answer = await run($, ['python3', `${checkout}/.agents/hooks/lib/config.py`, `${repo}/.agents/config.json`, 'hooks.status_band.enabled=true'])
  const word = answer.stdout.trim()
  if (answer.exitCode !== 0 || (word !== 'yes' && word !== 'no')) {
    throw new Error(`config.py answered ${JSON.stringify(word)} (exit ${answer.exitCode}): ${answer.stderr.trim()}`)
  }
  if (answer.stderr.trim() !== '') report($, `in ${repo}: ${answer.stderr.trim()}`)
  return word === 'yes'
}

/** The relay folder, or undefined where USER is unset. */
async function relayFolder($: EngineInterface): Promise<string | undefined> {
  const [tmp, user] = await Promise.all([$.env.get('TMPDIR'), $.env.get('USER')])
  return user === undefined || user === '' ? undefined : `${(tmp || '/tmp').replace(/\/$/, '')}/colloid-status-${user}`
}

/** A cancellation the engine made (an interrupted or superseded dispatch), not a fault. */
const isAbort = (error: unknown) => /\baborted\b/.test(String(error))

/** The marker, written with no process, so the relay goes silent at once. */
async function writeMarker($: EngineInterface, id: string): Promise<void> {
  const folder = await relayFolder($)
  if (folder === undefined || !ID.test(id)) return
  const marker = `${folder}/${id}.on`
  if (await $.fs.exists(marker)) return
  await $.fs.write(marker, `${id}\n`)
}

/**
 * The band for a session id, opened once: the marker first, then the opening
 * without waiting on it. An opening the engine aborted is tried again at the
 * next event; one that failed stays failed for its id, reported once, so a
 * broken switch is not read again on every draw.
 */
function begin($: EngineInterface, id: string): Opened {
  current?.session?.timer?.cancel()
  const marked = writeMarker($, id).catch((error: unknown) => {
    if (!isAbort(error)) report($, `the marker for ${id} was not written: ${String(error)}`)
  })
  const opened: Opened = { id, marked, session: undefined }
  current = opened
  marked
    .then(() => open($, id))
    .then(
      session => {
        if (current !== opened) {
          session.timer?.cancel()
          return
        }
        opened.session = session
        $.ui.invalidate('ui.render')
      },
      (error: unknown) => {
        if (isAbort(error)) {
          if (current === opened) current = undefined
          $.ui.log(`${$.plugin.name}: opening session ${id} was cut short: ${String(error)}`, { to: 'debug' })
          return
        }
        report($, `off for session ${id}: ${String(error)}`)
        // The person's own status line comes back.
        relayFolder($)
          .then(folder => removeRelayFiles($, folder, id))
          .catch((cleanup: unknown) => report($, `the marker for ${id} was not removed: ${String(cleanup)}`))
      },
    )
  return opened
}

/** The id the engine answers now, begun when new. */
async function seen($: EngineInterface): Promise<Opened> {
  const id = await $.session.id()
  return current?.id === id ? current : begin($, id)
}

async function open($: EngineInterface, id: string): Promise<Session> {
  const own = (await $.fs.stat($.plugin.root, { resolve: true })).realPath
  if (own === undefined) throw new Error('cannot resolve the mod folder')
  const checkout = own.split(/[\\/]/).slice(0, -4).join('/')
  const repo = await sessionRepository($, await $.session.root())
  const [home, profile, configDir, folder, usage, now] = await Promise.all([
    $.env.get('HOME'),
    $.env.get('CLAUDE_PROFILE'),
    $.env.get('CLAUDE_CONFIG_DIR'),
    relayFolder($),
    $.session.usage(),
    $.clock.now(),
  ])
  const session: Session = {
    id,
    repo,
    checkout,
    on: await switchIsOn($, checkout, repo),
    profile: { HOME: home, CLAUDE_PROFILE: profile, CLAUDE_CONFIG_DIR: configDir },
    folder,
    relay: undefined,
    fallback: undefined,
    git: null,
    gitCwd: undefined,
    gitAt: now,
    readouts: null,
    task: { ...NEW_TASK, startCost: usage.cost?.usd },
    view: 'full',
    refreshing: false,
    refreshAgain: false,
    timer: undefined,
    folderRefused: false,
  }
  if (!session.on) {
    await removeRelayFiles($, folder, id)
    return session
  }
  await ownFolder($, session)
  await readRelay($, session)
  await refresh($, session)
  session.fallback = session.relay === undefined ? await fallbackStatus($, session) : undefined
  session.timer = $.clock.every(POLL_MS, () => {
    poll($, session).catch((error: unknown) => report($, `the relay file was not read: ${String(error)}`))
  })
  return session
}

/**
 * Makes the relay folder this user's alone. The marker's write may have made
 * it with the default mode; a shared /tmp may hold another user's folder or
 * link under the name, which the relay then refuses to write through.
 */
async function ownFolder($: EngineInterface, session: Session): Promise<void> {
  if (session.folder === undefined) return
  const made = await run($, ['/bin/sh', '-c', '[ ! -L "$1" ] && mkdir -p "$1" && [ -O "$1" ] && chmod 700 "$1"', 'sh', session.folder])
  if (made.exitCode !== 0) {
    session.folderRefused = true
    report($, `${session.folder} is not this user's own folder; the person's own status line stays`)
  }
}

const relayFile = (session: Session, ext: 'on' | 'json') =>
  session.folder !== undefined && ID.test(session.id) ? `${session.folder}/${session.id}.${ext}` : undefined

/** The stat of a path, or undefined when it does not exist; other failures throw. */
async function statOrMissing($: EngineInterface, path: string) {
  return $.fs.stat(path).catch((error: unknown) => {
    if (String(error).includes('ENOENT')) return undefined
    throw error
  })
}

/** Reads the relay file when its mtime moved; true when the status changed. */
async function readRelay($: EngineInterface, session: Session): Promise<boolean> {
  const file = relayFile(session, 'json')
  if (file === undefined) return false
  const stat = await statOrMissing($, file)
  if (stat === undefined || stat.mtimeMs === session.relay?.mtimeMs) return false
  const text = await $.fs.read(file)
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    report($, `the relay file ${file} does not parse: ${String(error)}`)
    return false
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    report($, `the relay file ${file} holds no JSON object`)
    return false
  }
  session.relay = { mtimeMs: stat.mtimeMs, status: parsed as Json }
  return true
}

async function poll($: EngineInterface, session: Session): Promise<void> {
  if (!(await readRelay($, session))) return
  // The relay is written only while the engine draws, so this runs nothing
  // while the session is idle; it catches a commit made in another terminal.
  const cwd = statusCwd(session)
  const moved = cwd !== undefined && cwd !== session.gitCwd
  if (moved || (await $.clock.now()) - session.gitAt >= GIT_EVERY_MS) await refresh($, session)
  $.ui.invalidate('ui.render')
}

function statusCwd(session: Session): string | undefined {
  const workspace = session.relay?.status.workspace
  const cwd = workspace !== null && typeof workspace === 'object' ? (workspace as Json).current_dir : undefined
  return typeof cwd === 'string' && cwd !== '' ? cwd : undefined
}

/** git and the readouts, one refresh at a time; a call during one asks for one more. */
async function refresh($: EngineInterface, session: Session): Promise<void> {
  if (session.refreshing) {
    session.refreshAgain = true
    return
  }
  session.refreshing = true
  try {
    do {
      session.refreshAgain = false
      session.gitAt = await $.clock.now()
      const cwd = statusCwd(session) ?? (await $.session.cwd())
      const [git, readouts] = await Promise.all([readGit($, cwd), readReadouts($, session)])
      session.git = git
      session.gitCwd = cwd
      session.readouts = readouts
    } while (session.refreshAgain)
  } finally {
    session.refreshing = false
  }
}

function refreshInBackground($: EngineInterface, session: Session): void {
  refresh($, session)
    .then(() => $.ui.invalidate('ui.render'))
    .catch((error: unknown) => report($, `git and the readouts were not refreshed: ${String(error)}`))
}

// GIT_OPTIONAL_LOCKS=0: the band refreshes while agents run git in the same
// tree, and status would otherwise take index.lock against their commits.
async function readGit($: EngineInterface, cwd: string): Promise<Git | null> {
  const env = { GIT_OPTIONAL_LOCKS: '0' }
  // A folder git cannot start in (one since removed) shows no git segments, as
  // a folder outside a work tree does.
  const status = await run($, ['git', 'status', '--porcelain=v2', '--branch'], { cwd, env }).catch((error: unknown) => {
    $.ui.log(`${$.plugin.name}: git did not start in ${cwd}: ${String(error)}`, { to: 'debug' })
    return undefined
  })
  if (status === undefined || status.exitCode !== 0) return null
  const detached = status.stdout.includes('# branch.head (detached)\n')
  const short = detached ? await run($, ['git', 'rev-parse', '--short', 'HEAD'], { cwd, env }) : undefined
  return parseGit(status.stdout, short?.exitCode === 0 ? short.stdout : '')
}

// The reader starts only when the readout folder exists, so a repository no
// unit writes to pays nothing.
async function readReadouts($: EngineInterface, session: Session): Promise<string | null> {
  const folder = await statOrMissing($, `${session.repo}/.agents/.readout`)
  if (folder?.kind !== 'dir') return null
  const sessionId = session.relay?.status.session_id
  const answer: Answer | undefined = await run($, [
    'python3',
    `${session.repo}/.agents/hooks/lib/readout.py`,
    'strip',
    session.repo,
    typeof sessionId === 'string' ? sessionId : session.id,
  ]).catch((error: unknown) => {
    report($, `readout.py did not start: ${String(error)}`)
    return undefined
  })
  if (answer === undefined || answer.exitCode !== 0) return READER_FAILED
  return answer.stdout.replace(/\n+$/, '')
}

/** Puts back a marker something removed, with no process. */
async function keepMarker($: EngineInterface, session: Session): Promise<void> {
  const marker = relayFile(session, 'on')
  if (marker === undefined || session.folderRefused) return
  if (!(await $.fs.exists(marker))) await $.fs.write(marker, `${session.id}\n`)
}

async function removeRelayFiles($: EngineInterface, folder: string | undefined, id: string): Promise<void> {
  if (folder === undefined || !ID.test(id)) return
  const files = [`${folder}/${id}.on`, `${folder}/${id}.json`]
  const present = await Promise.all(files.map(file => $.fs.exists(file)))
  if (!present.some(Boolean)) return
  const removed = await run($, ['rm', '-f', ...files])
  if (removed.exitCode !== 0) report($, `could not remove ${files.join(' ')}: ${removed.stderr.trim()}`)
}

/** Before the first relay write, the figures the engine gives a mod. */
async function fallbackStatus($: EngineInterface, session: Session): Promise<Json> {
  const [usage, model, rows, cwd] = await Promise.all([$.session.usage(), $.session.model(), $.config.list(), $.session.cwd()])
  const row = (key: string) => rows.find(entry => entry.key === key)?.value
  const limit = (kind: string) => {
    const found = usage.rateLimits.find(entry => entry.kind === kind)
    if (found === undefined) return undefined
    const reset = found.resetsAt === undefined ? undefined : Math.floor(Date.parse(found.resetsAt) / 1000)
    return { used_percentage: found.percentUsed, resets_at: reset === undefined || Number.isNaN(reset) ? undefined : reset }
  }
  const style = row('outputStyle')
  return {
    session_id: session.id,
    transcript_path: '',
    workspace: { current_dir: cwd },
    model: { display_name: model },
    thinking: { enabled: row('thinking') === true },
    output_style: typeof style === 'string' ? { name: style } : undefined,
    context_window:
      usage.context.percent === undefined
        ? undefined
        : { used_percentage: usage.context.percent, context_window_size: usage.context.window, current_usage: { input_tokens: usage.context.tokens ?? 0 } },
    rate_limits: { five_hour: limit('five_hour'), seven_day: limit('seven_day') },
    cost: usage.cost === undefined ? undefined : { total_cost_usd: usage.cost.usd },
  }
}

function costNow(session: Session): number | undefined {
  const cost = session.relay?.status.cost
  const total = cost !== null && typeof cost === 'object' ? (cost as Json).total_cost_usd : undefined
  return typeof total === 'number' ? total : (session.task.lastCost ?? session.task.startCost)
}

function project(session: Session): string {
  const cwd = statusCwd(session) ?? session.repo
  return cwd.replace(/\/+$/, '').split('/').pop() ?? cwd
}

/** Row 4: what this task cost and did. */
function taskItems(session: Session): Run[] {
  const task = session.task
  const items: Run[] = []
  const cost = taskCost(task, costNow(session))
  if (cost !== undefined) items.push({ text: `${usd(cost)} task`, color: FG, bold: false })
  const last = task.turnCosts[task.turnCosts.length - 1]
  if (last !== undefined) items.push({ text: `last ${usd(last)}`, color: DIM, bold: false })
  items.push({ text: `${task.turns} ${task.turns === 1 ? 'turn' : 'turns'}`, color: DIM, bold: false })
  items.push({ text: `agent ${elapsed(task.busyMs)}`, color: DIM, bold: false })
  if (task.tests !== 'none') {
    const color = task.tests === 'pass' ? GREEN : task.tests === 'fail' ? RED : DIM
    items.push({ text: `tests ${task.tests}`, color, bold: false })
  }
  const callers = callersText(task.callers)
  if (callers !== undefined) items.push({ text: callers, color: YEL, bold: false })
  return items
}

function line($: EngineInterface, e: ResolveInput, runs: readonly Run[], key: string): RenderElement {
  const { Box, Text } = $.ui.resolve(e)
  return (
    <Box key={key} flexShrink={1}>
      <Text wrap="truncate-end">
        {runs.map(part => (
          <Text color={part.color ?? undefined} bold={part.bold}>
            {part.text}
          </Text>
        ))}
      </Text>
    </Box>
  )
}

/**
 * The band's own work after an engine event it passed on: never in the way of
 * that event's result, its failure reported instead.
 */
async function afterward($: EngineInterface, what: string, work: (session: Session) => void | Promise<void>): Promise<void> {
  try {
    const session = (await seen($)).session
    if (session?.on === true) await work(session)
  } catch (error) {
    if (!isAbort(error)) report($, `the band missed ${what}: ${String(error)}`)
  }
}

/**
 * The git top level of the session's own folder, so a worktree session reads
 * its own files and HEAD; the folder itself outside git.
 */
async function ownTopLevel($: EngineInterface, session: Session): Promise<string> {
  const folder = statusCwd(session) ?? (await $.session.cwd())
  const top = await run($, ['git', '-C', folder, 'rev-parse', '--show-toplevel'])
  return top.exitCode === 0 ? top.stdout.trim() : folder
}

/** Callers open: removed-callers.py over the task's edited Python files. */
async function checkCallers($: EngineInterface, session: Session): Promise<void> {
  const project = await ownTopLevel($, session)
  const answer = await run($, ['python3', `${session.checkout}/.agents/hooks/lib/removed-callers.py`, '--json', project], {
    stdin: `${session.task.editedPy.join('\n')}\n`,
  }).catch((error: unknown) => {
    report($, `removed-callers.py did not run: ${String(error)}`)
    return undefined
  })
  if (answer !== undefined && answer.exitCode !== 0) report($, `removed-callers.py failed: ${answer.stderr.trim()}`)
  session.task = { ...session.task, callers: answer === undefined ? { kind: 'failed' } : parseCallers(answer.exitCode, answer.stdout) }
  $.ui.invalidate('ui.render')
}

export const register: Register = on => {
  // The marker before anything else, so the relay's first run is silent.
  on('session.start', async ($, e, next) => {
    try {
      await (await seen($)).marked
    } catch (error) {
      if (!isAbort(error)) report($, `the band did not start: ${String(error)}`)
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.plugin !== $.plugin.name || e.props.hasSurvey) return next(e)
    const session = (await seen($)).session
    if (session === undefined || !session.on) return next(e)
    await keepMarker($, session)
    if (session.relay === undefined) session.fallback = await fallbackStatus($, session)
    const status = session.relay?.status ?? session.fallback ?? {}
    const rows = stripRows(status, session.profile, session.git, await $.clock.now(), session.readouts).filter(row => row.length > 0)

    const toggle = () => {
      session.view = session.view === 'full' ? 'line' : 'full'
      $.ui.invalidate('ui.render')
    }
    const copy = async () => {
      const text = markdown(session.task, { project: project(session), model: await $.session.model(), session: session.id, costNow: costNow(session) })
      const done = await $.ui.copy({ text, surface: e.surface })
      $.ui.toast(done.isCopied ? 'Task copied as Markdown' : `Copy failed: ${done.reason}`)
    }

    const { Box, Text, Button } = $.ui.resolve(e)
    const buttons = [
      <Button key="fold" plain label={session.view === 'full' ? 'One line' : 'Full'} onPress={toggle} />,
      <Button key="copy" plain label="Copy" onPress={copy} />,
    ]
    if (session.view === 'line') {
      const joined = merge([...(rows[0] ?? []), { text: '  ', color: DIM, bold: false }, ...(rows[1] ?? [])])
      return (
        <Box flexDirection="row" gap={2}>
          <Box flexGrow={1} flexShrink={1}>
            {line($, e, joined, 'line')}
          </Box>
          {buttons}
        </Box>
      )
    }
    return (
      <Box flexDirection="column">
        {rows.map((row, index) => line($, e, row, `row-${index + 1}`))}
        <Box key="row-4" flexDirection="row" gap={2}>
          {taskItems(session).map(item => (
            <Text color={item.color ?? undefined}>{item.text}</Text>
          ))}
          <Box flexGrow={1} />
          {buttons}
        </Box>
      </Box>
    )
  })

  // A test run sets the state, a later code edit makes it stale; git and the
  // readouts may have moved.
  on('tool.call', async ($, e, next) => {
    if (e.tool !== 'Bash' && e.tool !== 'Edit' && e.tool !== 'Write') return next(e)
    const ran = await next(e)
    if (ran.deny !== undefined) return ran
    await afterward($, 'a tool call', session => {
      // A background run resolves at once, before its tests ran.
      if (e.tool === 'Bash') {
        if (e.run_in_background !== true) session.task = afterBash(session.task, e.command, ran.isError === true)
      }
      else if (ran.isError !== true) session.task = afterEdit(session.task, e.file_path)
      refreshInBackground($, session)
    })
    return ran
  })

  on('prompt.submit', async ($, e, next) => {
    const submitted = await next(e)
    await afterward($, 'a prompt', session => refreshInBackground($, session))
    return submitted
  })

  on('turn.complete', async ($, e, next) => {
    const completed = await next(e)
    if (e.agentId !== undefined) return completed
    await afterward($, 'a turn', async session => {
      session.task = afterTurn(session.task, (await $.session.usage()).cost?.usd, e.durationMs)
      $.ui.invalidate('ui.render')
      if (session.task.editedPy.length > 0) await checkCallers($, session)
    })
    return completed
  })

  // Only the ending id's files go: the process may go on under a new id.
  on('session.end', async ($, e, next) => {
    if (current?.id === e.sessionId) {
      current.session?.timer?.cancel()
      current = undefined
    }
    await relayFolder($)
      .then(folder => removeRelayFiles($, folder, e.sessionId))
      .catch((error: unknown) => {
        if (!isAbort(error)) report($, `the relay files of ${e.sessionId} were not removed: ${String(error)}`)
      })
    return next(e)
  })
}
