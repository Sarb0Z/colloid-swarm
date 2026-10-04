import { test, expect } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

// The hooks a test registers sit beneath the mod and stand for the engine: the
// repository's files, config.py, guard-publish, the dialog, and Bash itself.
const REPO = '/repo'
const ASK = JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse', permissionDecision: 'ask',
    permissionDecisionReason: 'git push publishes commits to a remote.',
  },
})

type Answer = { readonly label: string } | { readonly afk: true } | { readonly dismissed: true }

type World = {
  readonly switched?: 'yes' | 'no'
  readonly guard?: (stdin: string) => string
  readonly answer?: Answer
  readonly exitCode?: number
}

type Seen = {
  readonly guardInputs: string[]
  readonly questions: string[]
  readonly writes: string[]
  readonly ran: { readonly command: string; readonly id: string }[]
}

function engine(on: On, world: World): Seen {
  const seen: Seen = { guardInputs: [], questions: [], writes: [], ran: [] }
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: REPO }))
  on('ui.log', () => ({ value: undefined }))
  on('fs.stat', () => ({ value: { kind: 'dir', size: 0, mtimeMs: 0, isLink: false, realPath: `${REPO}/.agents/claude/mods/publish-approval` } }))
  on('fs.write', ($, e) => {
    seen.writes.push(e.path)
    return { value: undefined }
  })
  on('process.run', ($, e) => {
    const done = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
    if (e.argv[1] === `${REPO}/.agents/hooks/lib/config.py`) return done(`${world.switched ?? 'yes'}\n`)
    const stdin = e.init?.stdin ?? ''
    seen.guardInputs.push(stdin)
    if (world.exitCode !== undefined) return { value: { exitCode: world.exitCode, stdout: '', stderr: 'ModuleNotFoundError', isStdoutTruncated: false, isStderrTruncated: false } }
    const guard = world.guard ?? ((input: string) => (input.includes('git push') ? ASK : ''))
    return done(guard(stdin))
  })
  on('tool.call', { tool: 'AskUserQuestion' }, ($, e) => {
    const asked = e.questions[0]
    if (asked === undefined) throw new Error('the dialog carried no question')
    seen.questions.push(asked.question)
    const answer = world.answer ?? { label: 'Run it' }
    if ('dismissed' in answer) return { deny: 'The user dismissed the dialog.' }
    const label = 'afk' in answer ? 'Run it' : answer.label
    return {
      result: {
        questions: e.questions, answers: { [asked.question]: label },
        ...('afk' in answer ? { afkTimeoutMs: 60000 } : {}),
      },
    }
  })
  on('tool.call', { tool: 'Bash' }, ($, e) => {
    seen.ran.push({ command: e.command, id: e.tool_use_id })
    return { result: { stdout: '', stderr: '', interrupted: false } }
  })
  return seen
}

async function start($: Engine) {
  await $.session.start({ cwd: REPO, surface: 'terminal', isInteractive: true })
}

test('Run it writes the token for that call, then the call goes on to the guard', async ($, on) => {
  const seen = engine(on, {})
  await start($)
  const ran = await $.tool.call({ tool: 'Bash', command: 'git push origin main' })
  expect(ran.deny).toBeUndefined()
  expect(seen.questions).toHaveLength(1)
  expect(seen.questions[0]).toContain('"git push origin main"')
  expect(seen.questions[0]).toContain('git push publishes commits to a remote.')
  expect(seen.ran).toHaveLength(1)
  const id = seen.ran[0]?.id
  expect(seen.writes).toEqual([`${REPO}/.agents/.publish-approved-${id}`])
  const asked: unknown = JSON.parse(seen.guardInputs[0] ?? '')
  expect(asked).toEqual({
    tool_name: 'Bash', tool_input: { command: 'git push origin main' }, tool_use_id: id,
    permission_mode: 'default', cwd: REPO, project_dir: REPO,
  })
})

test('Refuse denies the call and writes nothing', async ($, on) => {
  const seen = engine(on, { answer: { label: 'Refuse' } })
  await start($)
  const ran = await $.tool.call({ tool: 'Bash', command: 'git push' })
  expect(ran.deny).toContain('refused')
  expect(seen.ran).toHaveLength(0)
  expect(seen.writes).toHaveLength(0)
})

test('a dialog that resolved while the user was away approves nothing', async ($, on) => {
  const seen = engine(on, { answer: { afk: true } })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'git push' })
  expect(seen.questions).toHaveLength(1)
  expect(seen.writes).toHaveLength(0)
  expect(seen.ran).toHaveLength(1)
})

test('a dismissed dialog approves nothing', async ($, on) => {
  const seen = engine(on, { answer: { dismissed: true } })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'git push' })
  expect(seen.questions).toHaveLength(1)
  expect(seen.writes).toHaveLength(0)
  expect(seen.ran).toHaveLength(1)
})

test('text typed under Other approves nothing', async ($, on) => {
  const seen = engine(on, { answer: { label: 'Run it, but only to staging' } })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'git push' })
  expect(seen.questions).toHaveLength(1)
  expect(seen.writes).toHaveLength(0)
  expect(seen.ran).toHaveLength(1)
})

test('a call the guard lets through opens no dialog', async ($, on) => {
  const seen = engine(on, {})
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'ls -la' })
  expect(seen.guardInputs).toHaveLength(1)
  expect(seen.questions).toHaveLength(0)
  expect(seen.ran).toHaveLength(1)
})

test('a guard deny opens no dialog: only its ask is answerable', async ($, on) => {
  const deny = JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: 'hosted write' } })
  const seen = engine(on, { guard: () => deny })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'python3 /tmp/setup.py' })
  expect(seen.guardInputs).toHaveLength(1)
  expect(seen.questions).toHaveLength(0)
  expect(seen.writes).toHaveLength(0)
})

test('switched off in config, the mod never asks the guard', async ($, on) => {
  const seen = engine(on, { switched: 'no' })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'git push' })
  expect(seen.guardInputs).toHaveLength(0)
  expect(seen.questions).toHaveLength(0)
  expect(seen.ran).toHaveLength(1)
})

test('an unreadable guard answer passes the call through without a dialog', async ($, on) => {
  const seen = engine(on, { guard: () => 'Traceback (most recent call last):' })
  await start($)
  const ran = await $.tool.call({ tool: 'Bash', command: 'git push' })
  expect(ran.deny).toBeUndefined()
  expect(seen.guardInputs).toHaveLength(1)
  expect(seen.questions).toHaveLength(0)
  expect(seen.writes).toHaveLength(0)
  expect(seen.ran).toHaveLength(1)
})

test('a call too long to show whole opens no dialog and writes nothing', async ($, on) => {
  const seen = engine(on, {})
  await start($)
  await $.tool.call({ tool: 'Bash', command: `git push origin main && ${'x'.repeat(700)}` })
  expect(seen.guardInputs).toHaveLength(1)
  expect(seen.questions).toHaveLength(0)
  expect(seen.writes).toHaveLength(0)
  expect(seen.ran).toHaveLength(1)
})

test('control characters in the command are shown, not interpreted', async ($, on) => {
  const seen = engine(on, {})
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'git push\r\u001b[2Kecho harmless' })
  expect(seen.questions[0]).toContain('\\r\\u001b[2K')
})

test('a guard that exits non-zero opens no dialog', async ($, on) => {
  const seen = engine(on, { exitCode: 1 })
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'git push' })
  expect(seen.questions).toHaveLength(0)
  expect(seen.writes).toHaveLength(0)
  expect(seen.ran).toHaveLength(1)
})

test('the dialog works with no session start, as for a plugin loaded with the session', async ($, on) => {
  const seen = engine(on, {})
  await $.tool.call({ tool: 'Bash', command: 'git push' })
  expect(seen.questions).toHaveLength(1)
  expect(seen.writes).toHaveLength(1)
})
