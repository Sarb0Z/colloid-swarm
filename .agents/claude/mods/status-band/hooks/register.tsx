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
// nothing; without it the person's own status line draws. The session id is
// read on every draw, since /clear goes on under a new id with no
// session.start, and a new id starts the task over.
//
// Cost while idle: one in-process stat of the relay file every 2 s, and no
// process. git and readout.py run when the session starts, when the relay
// names another folder, at a prompt, and after a Bash, Edit or Write;
// removed-callers.py after a turn that edited Python files.
//
// The switch is hooks.status_band.enabled (default true) in the session
// repository's policy.json and config.json, read by this checkout's config.py.

type Json = Record<string, unknown>
type Answer = { exitCode: number; stdout: string; stderr: string }

const ID = /^[A-Za-z0-9_-]+$/
const POLL_MS = 2000
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
  readouts: string | null
  task: Task
  view: 'full' | 'line'
  refreshing: boolean
  refreshAgain: boolean
  timer: { cancel: () => void } | undefined
  /** The folder could not be made this user's own: the marker is never written. */
  folderRefused: boolean
}

let current: Promise<Session> | undefined
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

/** hooks.status_band.enabled, read by config.py; a file that does not parse turns it off. */
async function switchIsOn($: EngineInterface, checkout: string, repo: string): Promise<boolean> {
  const answer = await run($, ['python3', `${checkout}/.agents/hooks/lib/config.py`, `${repo}/.agents/config.json`, 'hooks.status_band.enabled=true'])
  const word = answer.stdout.trim()
  if (answer.exitCode !== 0 || (word !== 'yes' && word !== 'no')) {
    throw new Error(`config.py answered ${JSON.stringify(word)} (exit ${answer.exitCode}): ${answer.stderr.trim()}`)
  }
  if (answer.stderr.trim() !== '') {
    report($, `off in ${repo}: ${answer.stderr.trim()}`)
    return false
  }
  return word === 'yes'
}

async function open($: EngineInterface, id: string): Promise<Session> {
  const own = (await $.fs.stat($.plugin.root, { resolve: true })).realPath
  if (own === undefined) throw new Error('cannot resolve the mod folder')
  const checkout = own.split(/[\\/]/).slice(0, -4).join('/')
  const repo = await sessionRepository($, await $.session.root())
  const [home, profile, configDir, tmp, user, usage] = await Promise.all([
    $.env.get('HOME'),
    $.env.get('CLAUDE_PROFILE'),
    $.env.get('CLAUDE_CONFIG_DIR'),
    $.env.get('TMPDIR'),
    $.env.get('USER'),
    $.session.usage(),
  ])
  const session: Session = {
    id,
    repo,
    checkout,
    on: await switchIsOn($, checkout, repo),
    profile: { HOME: home, CLAUDE_PROFILE: profile, CLAUDE_CONFIG_DIR: configDir },
    folder: user === undefined || user === '' ? undefined : `${(tmp || '/tmp').replace(/\/$/, '')}/colloid-status-${user}`,
    relay: undefined,
    fallback: undefined,
    git: null,
    gitCwd: undefined,
    readouts: null,
    task: { ...NEW_TASK, startCost: usage.cost?.usd },
    view: 'full',
    refreshing: false,
    refreshAgain: false,
    timer: undefined,
    folderRefused: false,
  }
  if (session.on) {
    await readRelay($, session)
    await refresh($, session)
    session.timer = $.clock.every(POLL_MS, () => {
      poll($, session).catch((error: unknown) => report($, `the relay file was not read: ${String(error)}`))
    })
  }
  return session
}

/** The session for the id the engine answers now; a new id opens a new one. */
async function sessionFor($: EngineInterface): Promise<Session> {
  const id = await $.session.id()
  const known = current === undefined ? undefined : await current.catch(() => undefined)
  if (known?.id === id && current !== undefined) return current
  known?.timer?.cancel()
  current = open($, id)
  return current
}

const relayFile = (session: Session, ext: 'on' | 'json') =>
  session.folder !== undefined && ID.test(session.id) ? `${session.folder}/${session.id}.${ext}` : undefined

async function statOrMissing($: EngineInterface, path: string) {
  return $.fs.stat(path).catch(() => undefined)
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
  const cwd = statusCwd(session)
  if (cwd !== undefined && cwd !== session.gitCwd) await refresh($, session)
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
  const status = await run($, ['git', 'status', '--porcelain=v2', '--branch'], { cwd, env }).catch(() => undefined)
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
  ]).catch(() => undefined)
  if (answer === undefined || answer.exitCode !== 0) return READER_FAILED
  return answer.stdout.replace(/\n+$/, '')
}

async function ensureMarker($: EngineInterface, session: Session): Promise<void> {
  const marker = relayFile(session, 'on')
  if (marker === undefined || session.folder === undefined || session.folderRefused) return
  if (await $.fs.exists(marker)) return
  // A shared /tmp may hold a folder or link of another user's under the name.
  const made = await run($, ['/bin/sh', '-c', 'mkdir -p -m 700 "$1" && [ -O "$1" ] && [ ! -L "$1" ]', 'sh', session.folder])
  if (made.exitCode !== 0) {
    session.folderRefused = true
    report($, `${session.folder} is not this user's own folder; the person's own status line stays`)
    return
  }
  await $.fs.write(marker, `${session.id}\n`)
}

async function removeRelayFiles($: EngineInterface, session: Session, id: string): Promise<void> {
  if (session.folder === undefined || !ID.test(id)) return
  const files = [`${session.folder}/${id}.on`, `${session.folder}/${id}.json`]
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

export const register: Register = on => {
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.plugin !== $.plugin.name || e.props.hasSurvey) return next(e)
    const session = await sessionFor($)
    if (!session.on) {
      await removeRelayFiles($, session, session.id)
      return next(e)
    }
    await ensureMarker($, session)
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
    const session = await sessionFor($)
    if (!session.on) return ran
    if (e.tool === 'Bash') session.task = afterBash(session.task, e.command, ran.isError === true)
    else if (ran.isError !== true) session.task = afterEdit(session.task, e.file_path)
    refreshInBackground($, session)
    return ran
  })

  on('prompt.submit', async ($, e, next) => {
    const submitted = await next(e)
    const session = await sessionFor($)
    if (session.on) refreshInBackground($, session)
    return submitted
  })

  on('turn.complete', async ($, e, next) => {
    const completed = await next(e)
    if (e.agentId !== undefined) return completed
    const session = await sessionFor($)
    if (!session.on) return completed
    session.task = afterTurn(session.task, (await $.session.usage()).cost?.usd, e.durationMs)
    $.ui.invalidate('ui.render')
    if (session.task.editedPy.length > 0) {
      const answer = await run($, ['python3', `${session.checkout}/.agents/hooks/lib/removed-callers.py`, '--json', session.repo], {
        stdin: `${session.task.editedPy.join('\n')}\n`,
      }).catch((error: unknown) => {
        report($, `removed-callers.py did not run: ${String(error)}`)
        return undefined
      })
      if (answer !== undefined && answer.exitCode !== 0) report($, `removed-callers.py failed: ${answer.stderr.trim()}`)
      session.task = { ...session.task, callers: answer === undefined ? { kind: 'failed' } : parseCallers(answer.exitCode, answer.stdout) }
      $.ui.invalidate('ui.render')
    }
    return completed
  })

  // Only the ending id's files go: the process may go on under a new id.
  on('session.end', async ($, e, next) => {
    const session = current === undefined ? undefined : await current.catch(() => undefined)
    if (session !== undefined) {
      await removeRelayFiles($, session, e.sessionId)
      if (session.id === e.sessionId) {
        session.timer?.cancel()
        current = undefined
      }
    }
    return next(e)
  })
}
