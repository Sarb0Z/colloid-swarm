import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

import { merge } from '../hooks/strip'
import type { Run } from '../hooks/strip'
import { CAPTURES } from './golden/strip'
import type { Answer, Capture } from './golden/strip'

// The band through the engine: every noun it reads from outside (the session,
// the files, the processes, the clock, the environment) answered by the test
// as the real one would. The mod sits in the checkout /scaffold; the session
// runs in /work/app.

const FOLDER = '/tmp/colloid-status-tester'

type World = {
  id: string
  status?: Record<string, unknown>
  env?: Record<string, string>
  now?: number
  git?: Record<string, Answer> | null
  /** null: no readout folder; else readout.py's answer. */
  readouts?: Answer | null
  switchWord?: string
  markerExists?: boolean
  callers?: Answer
  /** The exit of making the relay folder this user's own. */
  folderExit?: number
  usage?: Record<string, unknown>
  configRows?: Record<string, unknown>[]
  /** The session's own folder; /work/app when not given. */
  cwd?: string
  /** What config.py says on stderr: a file it could not parse. */
  switchStderr?: string
  /** config.py answers only once this settles: a slow switch. */
  switchHeld?: Promise<void>
  /** How many git runs the engine aborts before answering. */
  gitAborts?: number
  /** How many readout.py runs the engine aborts before answering. */
  readoutAborts?: number
  /** git cannot start to name the session folder's top level. */
  topLevelFails?: boolean
  /** A file write lands only once this settles. */
  writeHeld?: Promise<void>
  /** Called as a held write begins. */
  onWrite?: () => void
}

function world(on: On, w: World) {
  const ran: (readonly string[])[] = []
  const stdins: (string | undefined)[] = []
  const written: { path: string; text: string }[] = []
  /** Every write and process start, in order: `write <path>` or `run <argv0>`. */
  const events: string[] = []
  const logged: string[] = []
  const files = new Map<string, string>()
  const mtimes = new Map<string, number>()
  const put = (path: string, text: string) => {
    files.set(path, text)
    mtimes.set(path, (mtimes.get(path) ?? 0) + 1)
  }
  if (w.status !== undefined) put(`${FOLDER}/${w.id}.json`, JSON.stringify(w.status))
  if (w.markerExists === true) put(`${FOLDER}/${w.id}.on`, `${w.id}\n`)
  const clock = mock.clock(on, { now: w.now ?? 1764300000000 })
  mock.env(on, { HOME: '/Users/fixture', TMPDIR: '/tmp/', USER: 'tester', ...(w.env ?? {}) })

  on('session.id', () => ({ value: w.id }))
  on('session.root', () => ({ value: '/work/app' }))
  on('session.cwd', () => ({ value: w.cwd ?? '/work/app' }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('ui.log', (_, e) => {
    logged.push(e.text)
    return { value: undefined }
  })
  on('session.model', () => ({ value: 'Fable 5.1' }))
  on('session.usage', () => ({ value: w.usage ?? { startedAt: 0, context: { window: 200000 }, rateLimits: [], cost: { usd: 1 } } }))
  on('config.list', () => ({ value: w.configRows ?? [] }))
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))
  on('fs.stat', (_, e) => {
    if (e.resolve) return { value: { kind: 'dir', size: 0, mtimeMs: 0, isLink: true, realPath: '/scaffold/.agents/claude/mods/status-band' } }
    if (e.path === '/work/app/.agents/.readout' && w.readouts !== undefined && w.readouts !== null) {
      return { value: { kind: 'dir', size: 0, mtimeMs: 0, isLink: false } }
    }
    if (files.has(e.path)) return { value: { kind: 'file', size: 1, mtimeMs: mtimes.get(e.path) ?? 0, isLink: false } }
    return { deny: `ENOENT: ${e.path}` }
  })
  on('fs.exists', (_, e) => ({ value: files.has(e.path) }))
  on('fs.read', (_, e) => {
    const text = files.get(e.path)
    return text === undefined ? { deny: `ENOENT: ${e.path}` } : { value: text }
  })
  on('fs.write', async (_, e) => {
    if (w.writeHeld !== undefined) {
      w.onWrite?.()
      await w.writeHeld
    }
    events.push(`write ${e.path}`)
    written.push({ path: e.path, text: e.text })
    put(e.path, e.text)
    return { value: undefined }
  })
  on('process.run', async (_, e) => {
    if (e.argv[0] === 'git' && (w.gitAborts ?? 0) > 0) {
      w.gitAborts = (w.gitAborts ?? 0) - 1
      return { deny: '$.process.run(git) aborted' }
    }
    if (e.argv[1]?.endsWith('/readout.py') === true && (w.readoutAborts ?? 0) > 0) {
      w.readoutAborts = (w.readoutAborts ?? 0) - 1
      return { deny: '$.process.run(python3) aborted' }
    }
    if (w.topLevelFails === true && e.argv.includes('--show-toplevel') && !e.argv.includes('--git-common-dir')) {
      return { deny: 'spawn git ENOMEM' }
    }
    if (e.argv[1]?.endsWith('/config.py') === true && w.switchHeld !== undefined) await w.switchHeld
    events.push(`run ${e.argv.join(' ')}`)
    ran.push(e.argv)
    stdins.push(e.init?.stdin)
    const answer = (a: Answer) => ({ value: { stderr: '', ...a, isStdoutTruncated: false, isStderrTruncated: false } })
    const [cmd, ...args] = e.argv
    // The session repository: /work/app, the main checkout of every folder here.
    if (cmd === 'git' && args[0] === '-C' && args.includes('--git-common-dir')) return answer({ exitCode: 0, stdout: '/work/app/.git\n/work/app\n' })
    // A folder's own top level: a worktree's is its own.
    if (cmd === 'git' && args[0] === '-C' && args.includes('--show-toplevel')) {
      const folder = args[1] ?? ''
      const worktree = /^\/work\/app\/\.claude\/worktrees\/[^/]+/.exec(folder)?.[0]
      return answer({ exitCode: 0, stdout: `${worktree ?? '/work/app'}\n` })
    }
    if (cmd === 'git') {
      const found = w.git?.[e.argv.join(' ')]
      return answer(found ?? { exitCode: 128, stdout: '', stderr: 'fatal: not a git repository (or any of the parent directories): .git\n' })
    }
    if (cmd === 'python3' && args[0]?.endsWith('/config.py')) {
      return answer({ exitCode: 0, stdout: `${w.switchWord ?? 'yes'}\n`, stderr: w.switchStderr ?? '' })
    }
    if (cmd === 'python3' && args[0]?.endsWith('/readout.py')) return answer(w.readouts ?? { exitCode: 2, stdout: '' })
    if (cmd === 'python3' && args[0]?.endsWith('/removed-callers.py')) return answer(w.callers ?? { exitCode: 0, stdout: '{"names": [], "sites": 0}\n' })
    if (cmd === '/bin/sh') return answer({ exitCode: w.folderExit ?? 0, stdout: '' })
    if (cmd === 'rm') {
      for (const file of args.slice(1)) files.delete(file)
      return answer({ exitCode: 0, stdout: '' })
    }
    return { deny: `unexpected command ${e.argv.join(' ')}` }
  })
  // Stands for what draws beneath the band: the engine's own row.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    const row = h(Text, {}, 'beneath')
    if (row === null || row === undefined || typeof row === 'string') throw new Error('h drew no element')
    return row
  })
  return { ran, stdins, written, files, clock, put, events, logged }
}

const BAND = (bodyColumns = 200) =>
  ({
    plugin: 'status-band',
    component: 'AbovePrompt',
    surface: 'terminal',
    props: {
      hasSurvey: false,
      isCollapsed: false,
      isWorking: false,
      maxRows: 20,
      bodyColumns,
      scroll: { offset: 0, bodyRows: 19 },
      view: {},
    },
  }) as const

type Node = { type?: string; key?: string; props?: Record<string, unknown>; children?: unknown[] }

/** Each drawn line's runs: a keyed row's Text, its child Texts read as text, colour and weight. */
function linesOf(tree: unknown): { key: string; runs: Run[] }[] {
  const found: { key: string; runs: Run[] }[] = []
  const walk = (node: unknown) => {
    if (node === null || typeof node !== 'object') return
    const n = node as Node
    const key = n.props?.key
    if (n.type === 'Box' && typeof key === 'string' && /^(row-[123]|line)$/.test(key)) {
      const text = (n.children ?? []).find(child => (child as Node).type === 'Text') as Node | undefined
      const runs = (text?.children ?? []).flatMap(child => {
        const c = child as Node
        if (c.type !== 'Text') return []
        const text = (c.children ?? []).filter(part => typeof part === 'string').join('')
        const color = typeof c.props?.color === 'string' ? c.props.color : null
        return [{ text, color, bold: c.props?.bold === true }]
      })
      found.push({ key, runs: merge(runs) })
      return
    }
    for (const child of n.children ?? []) walk(child)
  }
  walk(tree)
  return found
}

const plainText = (tree: unknown): string => {
  if (typeof tree === 'string') return tree
  if (tree === null || typeof tree !== 'object') return ''
  const n = tree as Node
  const own = typeof n.props?.label === 'string' ? `[${n.props.label}]` : ''
  return own + (n.children ?? []).map(plainText).join(n.type === 'Box' ? ' ' : '')
}

const captureWorld = (capture: Capture, index: number): World => ({
  id: `golden-${index}`,
  status: capture.status,
  env: capture.env,
  now: capture.now,
  git: capture.git,
  readouts: capture.readouts === null ? null : capture.readouts.answer,
})

const compared = CAPTURES.map((capture, index) => ({ capture, index })).filter(({ capture }) => !capture.name.startsWith('email'))

test('every capture but the two email badges is compared', async () => {
  expect(compared.length).toBe(49)
})

for (const { capture, index } of compared) {
  test(`rows 1 to 3 draw as the strip did: ${capture.name}`, async ($, on) => {
    const { ran } = world(on, captureWorld(capture, index))
    const ui = await $.ui.mount(BAND())
    const drawn = linesOf(await ui.drawn())
    const expected = capture.rows.map(merge).filter(row => row.length > 0)
    expect(drawn.filter(row => row.key.startsWith('row-')).map(row => row.runs)).toEqual(expected)
    // No readout folder, no reader start.
    if (capture.readouts === null) expect(ran.some(argv => argv.join(' ').includes('readout.py'))).toBe(false)
    await ui.unmount()
  })
}

const STATUS = {
  session_id: 'ignored-here',
  transcript_path: '/Users/fixture/.claude/projects/p/s.jsonl',
  workspace: { current_dir: '/work/app' },
  model: { display_name: 'Fable 5.1' },
  effort: { level: 'high' },
  cost: { total_cost_usd: 3.5 },
}
const TRUNK = { 'git status --porcelain=v2 --branch': { exitCode: 0, stdout: '# branch.oid 1\n# branch.head trunk\n' } }
const textOf = async (ui: { drawn: () => Promise<unknown> }) => plainText(await ui.drawn())
// The test's own engine beneath the band's hooks.
function engine(on: On, result: { isError: boolean; text: string }) {
  on('tool.call', () => ({ result: { stdout: result.text, stderr: '', interrupted: false }, text: result.text, isError: result.isError }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
}
const turn = (durationMs: number) => ({ answer: 'done', durationMs, isAborted: false, turnId: 't', reason: 'answer' }) as const

const FOLDER_CHECK = `run /bin/sh -c [ ! -L "$1" ] && mkdir -p -m 700 "$1" && [ -O "$1" ] sh ${FOLDER}`

/** The marker comes after the switch and the folder check, and before git status and the reader. */
function expectMarkerOrder(events: readonly string[], id: string) {
  const marker = events.indexOf(`write ${FOLDER}/${id}.on`)
  const sw = events.findIndex(event => event.includes('/config.py'))
  const folder = events.indexOf(FOLDER_CHECK)
  const status = events.findIndex(event => event.startsWith('run git status'))
  expect(sw).toBeGreaterThanOrEqual(0)
  expect(folder).toBeGreaterThan(sw)
  expect(marker).toBeGreaterThan(folder)
  if (status >= 0) expect(status).toBeGreaterThan(marker)
}

test('session.start writes the marker once the switch is on and the folder is this user\'s, before git and the readouts', async ($, on) => {
  const { written, events } = world(on, { id: 'start-1', status: STATUS, git: TRUNK })
  await $.session.start({ cwd: '/work/app', surface: 'terminal', isInteractive: true })
  expect(written).toEqual([{ path: `${FOLDER}/start-1.on`, text: 'start-1\n' }])
  expectMarkerOrder(events, 'start-1')
  const ui = await $.ui.mount(BAND())
  expect(await textOf(ui)).toContain('Fable 5.1')
  // The engine's own row stays beneath the band.
  expect(await textOf(ui)).toContain('beneath')
  await ui.unmount()
})

test('a draw that sees a new id writes its marker in the same order', async ($, on) => {
  const { events } = world(on, { id: 'marker-1', status: STATUS, git: TRUNK })
  const ui = await $.ui.mount(BAND())
  expectMarkerOrder(events, 'marker-1')
  await ui.unmount()
})

test('switched off, no marker is ever written', async ($, on) => {
  const { written } = world(on, { id: 'off-2', status: STATUS, git: TRUNK, switchWord: 'no' })
  await $.session.start({ cwd: '/work/app', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount(BAND())
  expect(await textOf(ui)).toBe('beneath')
  expect(written).toEqual([])
  await ui.unmount()
})

test('no draw waits on a process: until the opening finished, the band draws nothing of its own', async ($, on) => {
  let release = () => {}
  const held = new Promise<void>(resolve => {
    release = resolve
  })
  world(on, { id: 'slow-1', status: STATUS, git: TRUNK, switchHeld: held })
  const ui = await $.ui.mount(BAND())
  expect(await textOf(ui)).toBe('beneath')
  release()
  await ui.unmount()
  const later = await $.ui.mount(BAND())
  expect(await textOf(later)).toContain('Fable 5.1')
  await later.unmount()
})

test('an opening the engine aborted is retried on a timer, not reported, and draws once it succeeds', async ($, on) => {
  const { logged, ran, clock } = world(on, { id: 'abort-1', status: STATUS, git: TRUNK, gitAborts: 1 })
  const ui = await $.ui.mount(BAND())
  expect(await textOf(ui)).toBe('beneath')
  await clock.advance(250)
  expect(await textOf(ui)).toContain('Fable 5.1')
  expect(logged.filter(line => !line.includes('cut short'))).toEqual([])
  expect(ran.filter(argv => argv[1]?.endsWith('/config.py') === true).length).toBe(1)
  await ui.unmount()
})

test('after three aborted openings the band reports once and leaves no marker', async ($, on) => {
  const { logged, written, files, put, clock } = world(on, { id: 'abort-2', status: STATUS, git: TRUNK, gitAborts: 9 })
  put(`${FOLDER}/abort-2.nomod`, '')
  const ui = await $.ui.mount(BAND())
  await clock.advance(250)
  await clock.advance(500)
  await clock.advance(5000)
  expect(await textOf(ui)).toBe('beneath')
  expect(logged.filter(line => !line.includes('attempt'))).toEqual([
    "status-band: opening session abort-2 was cut short 3 times; the person's own status line stays",
  ])
  expect(written).toEqual([])
  expect(files.has(`${FOLDER}/abort-2.on`)).toBe(false)
  expect(files.has(`${FOLDER}/abort-2.nomod`)).toBe(true)
  await ui.unmount()
})

test('an opening retry still waiting when the id ends is cancelled and never runs', async ($, on) => {
  const w: World = { id: 'retry-end', status: STATUS, git: TRUNK, gitAborts: 9 }
  const { clock } = world(on, w)
  const ui = await $.ui.mount(BAND())
  expect(w.gitAborts).toBe(8)
  await $.session.end({ reason: 'clear', sessionId: 'retry-end', resume: { sessionId: 'retry-end' } })
  await clock.advance(5000)
  expect(w.gitAborts).toBe(8)
  await ui.unmount()
})

test('an opening retry of an id the session moved off is cancelled; the new id opens alone', async ($, on) => {
  const w: World = { id: 'retry-a', status: STATUS, git: TRUNK, gitAborts: 1 }
  const { clock, ran, written, put } = world(on, w)
  const first = await $.ui.mount(BAND())
  expect(w.gitAborts).toBe(0)
  w.id = 'retry-b'
  put(`${FOLDER}/retry-b.json`, JSON.stringify(STATUS))
  await first.unmount()
  const second = await $.ui.mount(BAND())
  await clock.advance(5000)
  expect(ran.filter(argv => argv[1]?.endsWith('/config.py') === true).length).toBe(1)
  expect(written.map(entry => entry.path)).toEqual([`${FOLDER}/retry-b.on`])
  await second.unmount()
})

test('an engine abort during a tool call refresh or a relay poll is not reported', async ($, on) => {
  const w: World = { id: 'refresh-abort', status: STATUS, git: TRUNK }
  const { logged, clock, put } = world(on, w)
  engine(on, { isError: false, text: 'ok' })
  const ui = await $.ui.mount(BAND())
  w.gitAborts = 1
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  await clock.settle()
  expect(w.gitAborts).toBe(0)
  w.gitAborts = 1
  put(`${FOLDER}/refresh-abort.json`, JSON.stringify({ ...STATUS, workspace: { current_dir: '/work/other' } }))
  await clock.advance(2000)
  expect(w.gitAborts).toBe(0)
  expect(logged).toEqual([])
  await ui.unmount()
})

test('a folder that is a link or another user\'s gets no marker, and the band still draws', async ($, on) => {
  const { written } = world(on, { id: 'marker-2', status: STATUS, git: TRUNK, folderExit: 1 })
  await $.session.start({ cwd: '/work/app', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount(BAND())
  expect(written).toEqual([])
  expect(await textOf(ui)).toContain('Fable 5.1')
  await ui.unmount()
})

test('an aborted reader is retried, never shown as a failed reader', async ($, on) => {
  const { logged, clock } = world(on, {
    id: 'reader-abort',
    status: STATUS,
    git: TRUNK,
    readouts: { exitCode: 0, stdout: '2 replies owed\n' },
    readoutAborts: 1,
  })
  const ui = await $.ui.mount(BAND())
  await clock.advance(250)
  const text = await textOf(ui)
  expect(text).toContain('2 replies owed')
  expect(text).not.toContain('reader failed')
  expect(logged.filter(line => line.includes('did not start'))).toEqual([])
  await ui.unmount()
})

test('an id that is no file name gets no marker', async ($, on) => {
  const { written } = world(on, { id: '../x', git: TRUNK })
  const ui = await $.ui.mount(BAND())
  expect(written).toEqual([])
  await ui.unmount()
})

test('a new session id (/clear) writes its own marker and starts the task over', async ($, on) => {
  const w: World = { id: 'clear-a', status: STATUS, git: TRUNK }
  const { written, put } = world(on, w)
  engine(on, { isError: false, text: '3 passed' })
  const ui = await $.ui.mount(BAND())
  await $.tool.call({ tool: 'Bash', command: 'pytest -q' })
  await $.turn.complete(turn(5000))
  expect(await textOf(ui)).toContain('tests pass')

  w.id = 'clear-b'
  put(`${FOLDER}/clear-b.json`, JSON.stringify({ ...STATUS, effort: { level: 'max' } }))
  await ui.unmount()
  const after = await $.ui.mount(BAND())
  const text = await textOf(after)
  expect(written.map(entry => entry.path)).toEqual([`${FOLDER}/clear-a.on`, `${FOLDER}/clear-b.on`])
  expect(text).toContain('max')
  expect(text).not.toContain('tests')
  expect(text).toContain('0 turns')
  await after.unmount()
})

test('session.end removes only the ending id\'s files', async ($, on) => {
  const { ran } = world(on, { id: 'end-1', status: STATUS, git: TRUNK })
  const ui = await $.ui.mount(BAND())
  await $.session.end({ reason: 'clear', sessionId: 'end-1', resume: { sessionId: 'end-1' } })
  expect(ran).toContainEqual(['rm', '-f', `${FOLDER}/end-1.on`, `${FOLDER}/end-1.json`, `${FOLDER}/end-1.nomod`])
  await ui.unmount()
})

test('session.end waits for a marker still being written, so none is left behind', async ($, on) => {
  let land = () => {}
  let writing = () => {}
  const started = new Promise<void>(resolve => {
    writing = resolve
  })
  const w: World = {
    id: 'end-2',
    status: STATUS,
    git: TRUNK,
    writeHeld: new Promise<void>(resolve => {
      land = resolve
    }),
    onWrite: () => writing(),
  }
  const { files, clock } = world(on, w)
  const ui = await $.ui.mount(BAND())
  await started
  const ended = $.session.end({ reason: 'clear', sessionId: 'end-2', resume: { sessionId: 'end-2' } })
  // session.end runs as far as it can before the write lands.
  await clock.settle()
  land()
  await ended
  expect(files.has(`${FOLDER}/end-2.on`)).toBe(false)
  await ui.unmount()
})

test('switched off, the band draws nothing of its own and takes its marker back, keeping the relay\'s .nomod', async ($, on) => {
  const { ran, files, put } = world(on, { id: 'off-1', status: STATUS, git: TRUNK, switchWord: 'no', markerExists: true })
  put(`${FOLDER}/off-1.nomod`, '')
  const ui = await $.ui.mount(BAND())
  const text = await textOf(ui)
  expect(text).toBe('beneath')
  expect(ran).toContainEqual(['rm', '-f', `${FOLDER}/off-1.on`, `${FOLDER}/off-1.json`])
  expect(files.has(`${FOLDER}/off-1.on`)).toBe(false)
  expect(files.has(`${FOLDER}/off-1.nomod`)).toBe(true)
  // Off, nothing but the switch and the removal runs: no git, no reader.
  expect(ran.filter(argv => argv[0] === 'git' && argv[1] !== '-C')).toEqual([])
  await ui.unmount()
})

test('a config file config.py cannot parse is reported once, and its answer stands', async ($, on) => {
  const stderr = 'config.py: /work/app/.agents/config.json is unreadable (Expecting value); every key in it falls back to its default\n'
  const { logged } = world(on, { id: 'parse-1', status: STATUS, git: TRUNK, switchWord: 'yes', switchStderr: stderr })
  const ui = await $.ui.mount(BAND())
  expect(await textOf(ui)).toContain('Fable 5.1')
  expect(logged).toEqual([`status-band: in /work/app: ${stderr.trim()}`])
  await ui.unmount()
})

test('a switch config.py cannot answer gives the line back, and is read once for the id', async ($, on) => {
  const { ran, files } = world(on, { id: 'broken-1', status: STATUS, git: TRUNK, switchWord: 'maybe' })
  const first = await $.ui.mount(BAND())
  expect(await textOf(first)).toBe('beneath')
  await first.unmount()
  const second = await $.ui.mount(BAND())
  expect(await textOf(second)).toBe('beneath')
  expect(ran.filter(argv => argv[1]?.endsWith('/config.py') === true).length).toBe(1)
  // The marker the band wrote first is gone, so the person's own line draws.
  expect(files.has(`${FOLDER}/broken-1.on`)).toBe(false)
  await second.unmount()
})

test('the reader gets the relay\'s own session id, and its empty answer draws no row 3', async ($, on) => {
  const { ran } = world(on, { id: 'reader-1', status: { ...STATUS, session_id: 'sess-9' }, git: TRUNK, readouts: { exitCode: 0, stdout: '\n' } })
  const ui = await $.ui.mount(BAND())
  expect(ran).toContainEqual(['python3', '/work/app/.agents/hooks/lib/readout.py', 'strip', '/work/app', 'sess-9'])
  expect(linesOf(await ui.drawn()).map(row => row.key)).toEqual(['row-1', 'row-2'])
  await ui.unmount()
})

test('a passing pytest run shows tests pass; a later .py edit, stale', async ($, on) => {
  world(on, { id: 'tests-1', status: STATUS, git: TRUNK })
  engine(on, { isError: false, text: '5 passed' })
  const ui = await $.ui.mount(BAND())
  expect(await textOf(ui)).not.toContain('tests')
  await $.tool.call({ tool: 'Bash', command: 'uv run pytest tests/ -q' })
  expect(await textOf(ui)).toContain('tests pass')
  await $.tool.call({ tool: 'Edit', file_path: '/work/app/src/a.py', old_string: 'a', new_string: 'b' })
  expect(await textOf(ui)).toContain('tests stale')
  await ui.unmount()
})

test('a failing test run shows tests fail; a Bash command that runs no tests changes nothing', async ($, on) => {
  world(on, { id: 'tests-2', status: STATUS, git: TRUNK })
  engine(on, { isError: true, text: '1 failed' })
  const ui = await $.ui.mount(BAND())
  await $.tool.call({ tool: 'Bash', command: 'npm test' })
  expect(await textOf(ui)).toContain('tests fail')
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(await textOf(ui)).toContain('tests fail')
  await ui.unmount()
})

test('a failing pytest piped into tail leaves the tests state as it was', async ($, on) => {
  world(on, { id: 'tests-3', status: STATUS, git: TRUNK })
  // tail exits 0 whatever pytest said: the call resolves with no error.
  engine(on, { isError: false, text: '1 failed, 4 passed' })
  const ui = await $.ui.mount(BAND())
  await $.tool.call({ tool: 'Bash', command: 'pytest -q 2>&1 | tail -20' })
  expect(await textOf(ui)).not.toContain('tests')
  await ui.unmount()
})

test('a test run sent to the background leaves the tests state as it was', async ($, on) => {
  world(on, { id: 'tests-4', status: STATUS, git: TRUNK })
  engine(on, { isError: false, text: 'Command running in background' })
  const ui = await $.ui.mount(BAND())
  await $.tool.call({ tool: 'Bash', command: 'pytest -q', run_in_background: true })
  expect(await textOf(ui)).not.toContain('tests')
  await ui.unmount()
})

test('this repository\'s own test scripts set the tests state, pass and fail', async ($, on) => {
  let failing = false
  world(on, { id: 'tests-5', status: STATUS, git: TRUNK })
  on('tool.call', () => ({ result: { stdout: '', stderr: '', interrupted: false }, text: '', isError: failing }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  const ui = await $.ui.mount(BAND())
  await $.tool.call({ tool: 'Bash', command: 'bash .agents/test-owed.sh' })
  expect(await textOf(ui)).toContain('tests pass')
  failing = true
  await $.tool.call({ tool: 'Bash', command: 'bash .agents/test-owed.sh' })
  expect(await textOf(ui)).toContain('tests fail')
  await ui.unmount()
})

test('after a turn that renamed a function called in two other files, 2 callers open', async ($, on) => {
  const { ran, stdins } = world(on, { id: 'callers-1', status: STATUS, git: TRUNK, callers: { exitCode: 0, stdout: '{"names": ["total_price"], "sites": 2}\n' } })
  engine(on, { isError: false, text: '' })
  const ui = await $.ui.mount(BAND())
  await $.tool.call({ tool: 'Edit', file_path: '/work/app/lib.py', old_string: 'total_price', new_string: 'order_total' })
  await $.tool.call({ tool: 'Write', file_path: '/work/app/notes.md', content: 'x' })
  await $.turn.complete(turn(2000))
  const index = ran.findIndex(argv => argv[1]?.endsWith('/removed-callers.py') === true)
  expect(ran[index]).toEqual(['python3', '/scaffold/.agents/hooks/lib/removed-callers.py', '--json', '/work/app'])
  expect(stdins[index]).toBe('/work/app/lib.py\n')
  expect(await textOf(ui)).toContain('2 callers open')
  await ui.unmount()
})

test('in a worktree session the callers check reads the worktree\'s own files', async ($, on) => {
  const tree = '/work/app/.claude/worktrees/lane'
  const { ran } = world(on, {
    id: 'callers-3',
    status: { ...STATUS, workspace: { current_dir: `${tree}/src` } },
    git: TRUNK,
    callers: { exitCode: 0, stdout: '{"names": ["total_price"], "sites": 1}\n' },
  })
  engine(on, { isError: false, text: '' })
  const ui = await $.ui.mount(BAND())
  await $.tool.call({ tool: 'Edit', file_path: `${tree}/lib.py`, old_string: 'a', new_string: 'b' })
  await $.turn.complete(turn(2000))
  expect(ran.find(argv => argv[1]?.endsWith('/removed-callers.py') === true)).toEqual([
    'python3',
    '/scaffold/.agents/hooks/lib/removed-callers.py',
    '--json',
    tree,
  ])
  expect(await textOf(ui)).toContain('1 callers open')
  await ui.unmount()
})

test('when git cannot name the session folder\'s top level, callers ?', async ($, on) => {
  const { ran } = world(on, { id: 'callers-4', status: STATUS, git: TRUNK, topLevelFails: true })
  engine(on, { isError: false, text: '' })
  const ui = await $.ui.mount(BAND())
  await $.tool.call({ tool: 'Edit', file_path: '/work/app/lib.py', old_string: 'a', new_string: 'b' })
  await $.turn.complete(turn(2000))
  expect(await textOf(ui)).toContain('callers ?')
  expect(ran.some(argv => argv[1]?.endsWith('/removed-callers.py') === true)).toBe(false)
  await ui.unmount()
})

test('when removed-callers.py fails, callers ?', async ($, on) => {
  world(on, { id: 'callers-2', status: STATUS, git: TRUNK, callers: { exitCode: 1, stdout: '', stderr: 'removed-callers: failed, git' } })
  engine(on, { isError: false, text: '' })
  const ui = await $.ui.mount(BAND())
  await $.tool.call({ tool: 'Edit', file_path: '/work/app/lib.py', old_string: 'a', new_string: 'b' })
  await $.turn.complete(turn(2000))
  expect(await textOf(ui)).toContain('callers ?')
  await ui.unmount()
})

test('a turn with no Python edit runs no callers check, and adds its cost and time', async ($, on) => {
  const w: World = { id: 'turn-1', status: { ...STATUS, cost: undefined }, git: TRUNK }
  const { ran } = world(on, w)
  engine(on, { isError: false, text: '' })
  const ui = await $.ui.mount(BAND())
  w.usage = { startedAt: 0, context: { window: 200000 }, rateLimits: [], cost: { usd: 1.25 } }
  await $.turn.complete(turn(250000))
  expect(ran.some(argv => argv[1]?.endsWith('/removed-callers.py') === true)).toBe(false)
  const text = await textOf(ui)
  expect(text).toContain('$0.25 task')
  expect(text).toContain('last $0.25')
  expect(text).toContain('1 turn')
  expect(text).toContain('agent 4m 10s')
  await ui.unmount()
})

test('idle, the band starts no process; a relay write runs git at most once per 5 s unless it names another folder', async ($, on) => {
  const { ran, clock, put } = world(on, { id: 'idle-1', status: STATUS, git: TRUNK })
  const ui = await $.ui.mount(BAND())
  const before = ran.length
  const gitRuns = () => ran.slice(before).filter(argv => argv[0] === 'git').length
  // Idle: the relay file does not change, and nothing starts.
  await clock.advance(60000)
  expect(ran.slice(before)).toEqual([])

  // A relay write in the same folder, past 5 s since git last ran: git once,
  // so a commit made in another terminal shows.
  put(`${FOLDER}/idle-1.json`, JSON.stringify({ ...STATUS, cost: { total_cost_usd: 3.5, total_duration_ms: 720000 } }))
  await clock.advance(2000)
  expect(ran.slice(before)).toEqual([['git', 'status', '--porcelain=v2', '--branch']])
  expect(await textOf(ui)).toContain('󰔛 12m')

  // Within 5 s of that run, a write in the same folder redraws with no process.
  put(`${FOLDER}/idle-1.json`, JSON.stringify({ ...STATUS, cost: { total_cost_usd: 3.5, total_duration_ms: 780000 } }))
  await clock.advance(2000)
  expect(gitRuns()).toBe(1)
  expect(await textOf(ui)).toContain('󰔛 13m')

  // A write naming another folder runs git at once.
  put(`${FOLDER}/idle-1.json`, JSON.stringify({ ...STATUS, workspace: { current_dir: '/work/other' } }))
  await clock.advance(2000)
  expect(gitRuns()).toBe(2)
  expect(await textOf(ui)).toContain(' other')
  await ui.unmount()
})

test('One line folds the band to one row and Full brings it back', async ($, on) => {
  world(on, { id: 'fold-1', status: STATUS, git: TRUNK })
  const ui = await $.ui.mount(BAND())
  await ui.press({ key: 'fold' })
  const folded = linesOf(await ui.drawn())
  expect(folded.map(row => row.key)).toEqual(['line'])
  expect(folded[0]?.runs.map(run => run.text).join('')).toContain('trunk')
  expect(folded[0]?.runs.map(run => run.text).join('')).toContain('Fable 5.1')
  expect(await textOf(ui)).toContain('[Full]')
  await ui.press({ key: 'fold' })
  expect(linesOf(await ui.drawn()).map(row => row.key)).toEqual(['row-1', 'row-2'])
  await ui.unmount()
})

test('Copy puts the task on the clipboard as Markdown', async ($, on) => {
  world(on, { id: 'copy-1', status: STATUS, git: TRUNK })
  const copied: string[] = []
  on('ui.copy', (_, e) => {
    copied.push(e.text)
    return { value: { isCopied: true } }
  })
  const ui = await $.ui.mount(BAND())
  await ui.press({ key: 'copy' })
  expect(copied.length).toBe(1)
  expect(copied[0]).toContain('| Project | app |')
  expect(copied[0]).toContain('| Cost | $2.50 |')
  expect(copied[0]).toContain('| Session | `copy-1` |')
  await ui.unmount()
})

test('before the first relay write, the band draws what the engine gives', async ($, on) => {
  world(on, {
    id: 'fallback-1',
    git: TRUNK,
    usage: { startedAt: 0, context: { window: 1000000, percent: 42, tokens: 420000 }, rateLimits: [{ kind: 'seven_day', percentUsed: 18 }], cost: { usd: 0 } },
    configRows: [
      { key: 'thinking', label: 'Thinking', kind: 'boolean', value: true, provider: { kind: 'engine' }, isLocked: false },
      { key: 'outputStyle', label: 'Output style', kind: 'enum', value: 'colloid', provider: { kind: 'engine' }, isLocked: false },
    ],
  })
  const ui = await $.ui.mount(BAND())
  const rows = linesOf(await ui.drawn())
  expect(rows[1]?.runs.map(run => run.text).join('')).toBe('Fable 5.1 󰧑  ━━━━┄┄┄┄┄┄ 420K/1.0M  7d 18%  style:colloid')
  await ui.unmount()
})
