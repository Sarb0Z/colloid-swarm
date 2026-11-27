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
}

function world(on: On, w: World) {
  const ran: (readonly string[])[] = []
  const stdins: (string | undefined)[] = []
  const written: { path: string; text: string }[] = []
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
  on('session.cwd', () => ({ value: '/work/app' }))
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
  on('fs.write', (_, e) => {
    written.push({ path: e.path, text: e.text })
    put(e.path, e.text)
    return { value: undefined }
  })
  on('process.run', (_, e) => {
    ran.push(e.argv)
    stdins.push(e.init?.stdin)
    const answer = (a: Answer) => ({ value: { stderr: '', ...a, isStdoutTruncated: false, isStderrTruncated: false } })
    const [cmd, ...args] = e.argv
    if (cmd === 'git' && args[0] === '-C') return answer({ exitCode: 0, stdout: '/work/app/.git\n/work/app\n' })
    if (cmd === 'git') {
      const found = w.git?.[e.argv.join(' ')]
      return answer(found ?? { exitCode: 128, stdout: '', stderr: 'fatal: not a git repository (or any of the parent directories): .git\n' })
    }
    if (cmd === 'python3' && args[0]?.endsWith('/config.py')) return answer({ exitCode: 0, stdout: `${w.switchWord ?? 'yes'}\n` })
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
  return { ran, stdins, written, files, clock, put }
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

test('the first draw writes the marker in a folder made for this user alone', async ($, on) => {
  const { ran, written } = world(on, { id: 'marker-1', status: STATUS, git: TRUNK })
  const ui = await $.ui.mount(BAND())

  expect(ran).toContainEqual(['/bin/sh', '-c', 'mkdir -p -m 700 "$1" && [ -O "$1" ] && [ ! -L "$1" ]', 'sh', FOLDER])
  expect(written).toEqual([{ path: `${FOLDER}/marker-1.on`, text: 'marker-1\n' }])
  // The engine's own row stays beneath the band.
  expect(await textOf(ui)).toContain('beneath')
  await ui.unmount()
})

test('a folder that is not this user\'s own gets no marker, and the band still draws', async ($, on) => {
  const { written } = world(on, { id: 'marker-2', status: STATUS, git: TRUNK, folderExit: 1 })
  const ui = await $.ui.mount(BAND())
  expect(written).toEqual([])
  expect(await textOf(ui)).toContain('Fable 5.1')
  await ui.unmount()
})

test('an id that is no file name gets no marker', async ($, on) => {
  const { written, ran } = world(on, { id: '../x', git: TRUNK })
  const ui = await $.ui.mount(BAND())
  expect(written).toEqual([])
  expect(ran.some(argv => argv[0] === '/bin/sh')).toBe(false)
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
  expect(ran).toContainEqual(['rm', '-f', `${FOLDER}/end-1.on`, `${FOLDER}/end-1.json`])
  await ui.unmount()
})

test('switched off, the band draws nothing of its own and takes its marker back', async ($, on) => {
  const { ran, written } = world(on, { id: 'off-1', status: STATUS, git: TRUNK, switchWord: 'no', markerExists: true })
  const ui = await $.ui.mount(BAND())
  const text = await textOf(ui)
  expect(text).toBe('beneath')
  expect(written).toEqual([])
  expect(ran).toContainEqual(['rm', '-f', `${FOLDER}/off-1.on`, `${FOLDER}/off-1.json`])
  // Off, nothing but the switch and the removal runs: no git, no reader.
  expect(ran.filter(argv => argv[0] === 'git' && argv[1] !== '-C')).toEqual([])
  await ui.unmount()
})

test('a switch config.py cannot answer leaves the person\'s own line, read once for the id', async ($, on) => {
  const { ran, written } = world(on, { id: 'broken-1', status: STATUS, git: TRUNK, switchWord: 'maybe' })
  const first = await $.ui.mount(BAND())
  expect(await textOf(first)).toBe('beneath')
  await first.unmount()
  const second = await $.ui.mount(BAND())
  expect(await textOf(second)).toBe('beneath')
  expect(ran.filter(argv => argv[1]?.endsWith('/config.py') === true).length).toBe(1)
  expect(written).toEqual([])
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

test('idle, the band starts no process; a relay write naming another folder runs git once', async ($, on) => {
  const { ran, clock, put } = world(on, { id: 'idle-1', status: STATUS, git: TRUNK })
  const ui = await $.ui.mount(BAND())
  const before = ran.length
  await clock.advance(60000)
  expect(ran.slice(before)).toEqual([])

  // The same folder, a later duration: redrawn in-process, no process.
  put(`${FOLDER}/idle-1.json`, JSON.stringify({ ...STATUS, cost: { total_cost_usd: 3.5, total_duration_ms: 720000 } }))
  await clock.advance(2000)
  expect(ran.slice(before)).toEqual([])
  expect(await textOf(ui)).toContain('󰔛 12m')

  put(`${FOLDER}/idle-1.json`, JSON.stringify({ ...STATUS, workspace: { current_dir: '/work/other' } }))
  await clock.advance(2000)
  expect(ran.slice(before).filter(argv => argv[0] === 'git')).toEqual([['git', 'status', '--porcelain=v2', '--branch']])
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
