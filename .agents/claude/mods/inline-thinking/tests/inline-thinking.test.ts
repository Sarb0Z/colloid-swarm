import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'

import { collect, merge, promptKey, sameAnchors, signatureKind, textKey } from '../hooks/anchors'
import { switchIsOn } from '../hooks/register'
import type { SwitchIO } from '../hooks/register'

// Signatures shaped like Claude Code's: protobuf field 2 → 1 → 8 holding the
// block's kind, after a varint field the decoder must skip.
const NARRATION = 'CAESDQoLQgluYXJyYXRpb24='
const THINKING = 'CAESDAoKQgh0aGlua2luZw=='

const thinking = (text: string, signature: string) => ({ type: 'thinking', thinking: text, signature })
const prompt = (...texts: string[]) => ({
  role: 'user' as const,
  content: texts.map(text => ({ type: 'text', text })),
})
const reply = (...content: { type: string; [field: string]: unknown }[]) => ({ role: 'assistant' as const, content })

test('a signature names its block as narration or thinking', async () => {
  expect(signatureKind(NARRATION)).toBe('narration')
  expect(signatureKind(THINKING)).toBe('thinking')
  expect(signatureKind('')).toBe(undefined)
  expect(signatureKind('not base64!')).toBe(undefined)
})

test('each summary is keyed to a row that knows the view', async () => {
  const { anchors, keys } = collect([
    prompt('<system-reminder>today is Monday</system-reminder>', 'check the build'),
    reply(
      thinking('Plan: read the log first.', THINKING),
      thinking('Reading the build log now.', NARRATION),
      thinking('The log names the failing step.', THINKING),
      { type: 'tool_use', id: 'toolu_1', name: 'Bash', input: {} },
    ),
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content: 'ok' }] },
    reply(thinking('Deciding what to report.', THINKING), { type: 'text', text: 'The build  passes.' }),
    reply(thinking('A second thought between replies.', THINKING), { type: 'text', text: 'One more note.' }),
    reply(thinking('Left over, nothing follows.', THINKING)),
    prompt('thanks'),
    reply({ type: 'text', text: 'Done.' }),
  ])

  // Before a narration line, right after the prompt: below the prompt row.
  expect(anchors[promptKey('check the build')]).toEqual(['Plan: read the log first.'])
  expect(anchors[textKey('Reading the build log now.')]).toBe(undefined)
  // Before a tool call: above the call.
  expect(anchors['tool:toolu_1']).toEqual(['The log names the failing step.'])
  // Before a reply, right after a call: below the call's result.
  expect(anchors['after-tool:toolu_1']).toEqual(['Deciding what to report.'])
  // Between two replies: above the second.
  expect(anchors[textKey('One more  note.')]).toEqual(['A second thought between replies.'])
  // A prompt drops what nothing followed.
  expect(anchors[textKey('Done.')]).toBe(undefined)
  expect(anchors[promptKey('thanks')]).toBe(undefined)
  // A reminder is no row.
  expect(keys.has(promptKey('<system-reminder>today is Monday</system-reminder>'))).toBe(false)
  expect(Object.keys(anchors).length).toBe(4)
})

test('a summary two rows could own draws at neither', async () => {
  const { anchors } = collect([
    prompt('yes'),
    reply(thinking('Weighing the first yes.', THINKING), thinking('Applying the fix.', NARRATION)),
    prompt('check the tests'),
    reply(thinking('Reading the test output.', THINKING), thinking('Running the tests.', NARRATION)),
    prompt('yes'),
    reply({ type: 'text', text: 'Committed.' }),
    reply(thinking('Between two replies.', THINKING), { type: 'text', text: 'Done.' }),
    reply({ type: 'text', text: 'Done.' }),
  ])

  expect(anchors[promptKey('yes')]).toBe(undefined)
  expect(anchors[textKey('Done.')]).toBe(undefined)
  expect(anchors[promptKey('check the tests')]).toEqual(['Reading the test output.'])
  expect(Object.keys(anchors).length).toBe(1)
})

test('a prompt with no typed text leaves its summary to the next row', async () => {
  const { anchors } = collect([
    {
      role: 'user',
      content: [
        { type: 'text', text: '<command-name>/review</command-name>\n<command-args>src</command-args>' },
        { type: 'text', text: 'Base directory for this skill: /skills/review' },
      ],
    },
    reply(thinking('Choosing what to read first.', THINKING), thinking('Opening the diff.', NARRATION)),
    { role: 'user', content: [{ type: 'image', source: { type: 'base64', media_type: 'image/png', data: '' } }] },
    reply(thinking('The screenshot shows a cut-off label.', THINKING), { type: 'text', text: 'The label is clipped.' }),
  ])

  expect(anchors[textKey('Opening the diff.')]).toEqual(['Choosing what to read first.'])
  expect(anchors[textKey('The label is clipped.')]).toEqual(['The screenshot shows a cut-off label.'])
  expect(anchors[promptKey('Base directory for this skill: /skills/review')]).toBe(undefined)
})

test('calls made together keep the summary before them above the first, the next one below the last', async () => {
  const { anchors } = collect([
    prompt('read both files'),
    reply(
      thinking('Both files are needed.', THINKING),
      { type: 'tool_use', id: 'toolu_a', name: 'Read', input: {} },
      { type: 'tool_use', id: 'toolu_b', name: 'Read', input: {} },
    ),
    {
      role: 'user',
      content: [
        { type: 'tool_result', tool_use_id: 'toolu_a', content: 'a' },
        { type: 'tool_result', tool_use_id: 'toolu_b', content: 'b' },
      ],
    },
    reply(thinking('They agree.', THINKING), { type: 'text', text: 'Both files say the same.' }),
  ])

  expect(anchors).toEqual({ 'tool:toolu_a': ['Both files are needed.'], 'after-tool:toolu_b': ['They agree.'] })
})

test('a long summary is cut with a mark', async () => {
  const { anchors } = collect([
    prompt('go'),
    reply(thinking('x'.repeat(5000), THINKING), { type: 'tool_use', id: 'toolu_1', name: 'Bash', input: {} }),
  ])

  const [summary] = anchors['tool:toolu_1'] ?? []
  expect(summary?.length).toBe(4000)
  expect(summary?.endsWith('x…')).toBe(true)
})

test('the conversation decides its own keys, and a compacted one keeps its old summaries', async () => {
  const collected = collect([prompt('yes'), reply({ type: 'text', text: 'Committed.' })])

  expect(
    merge({ [promptKey('yes')]: ['From before the clear.'], 'tool:toolu_old': ['Compacted away.'] }, collected),
  ).toEqual({ 'tool:toolu_old': ['Compacted away.'] })
})

test('past 400 anchors the newest stay, and a second read changes nothing', async () => {
  const messages = Array.from({ length: 401 }, (_, i) =>
    reply(thinking(`Step ${i + 1}.`, THINKING), { type: 'tool_use', id: `toolu_${i + 1}`, name: 'Bash', input: {} }),
  )
  const collected = collect(messages)
  const once = merge({}, collected)

  expect(Object.keys(once).length).toBe(400)
  expect(once['tool:toolu_1']).toBe(undefined)
  expect(once['tool:toolu_2']).toEqual(['Step 2.'])
  expect(once['tool:toolu_401']).toEqual(['Step 401.'])
  expect(sameAnchors(once, merge(once, collected))).toBe(true)
})

// The session runs in a worktree of /work/app; the mod sits in the checkout
// /scaffold. `git` and `config` are what each command answers.
type Answer = { exitCode: number; stdout: string; stderr: string }

function fakeSwitch(preset: string | undefined, config: Answer, git?: Answer) {
  const asked: (readonly string[])[] = []
  const logged: string[] = []
  const io: SwitchIO = {
    realPath: async () => '/scaffold/.agents/claude/mods/inline-thinking',
    cwd: '/work/app/.claude/worktrees/x',
    run: async argv => {
      asked.push(argv)
      if (argv[0] !== 'git') return config
      return git ?? { exitCode: 0, stdout: '/work/app/.git\n/work/app/.claude/worktrees/x\n', stderr: '' }
    },
    preset: async () => preset,
    log: line => logged.push(line),
  }
  return { io, asked, logged }
}

const says = (word: string): Answer => ({ exitCode: 0, stdout: `${word}\n`, stderr: '' })

test('the switch is off unless the operator presets it', async () => {
  const { io, asked } = fakeSwitch(undefined, says('no'))

  expect(await switchIsOn(io)).toBe(false)
  // The session repository's own files decide, read from its main checkout.
  expect(asked[1]).toEqual([
    'python3', '/scaffold/.agents/hooks/lib/config.py', '/work/app/.agents/config.json',
    'hooks.inline_thinking.enabled=false',
  ])
})

test('the machine-wide preset turns it on where a repository is silent', async () => {
  const { io, asked } = fakeSwitch('true', says('yes'))

  expect(await switchIsOn(io)).toBe(true)
  expect(asked[1]?.at(-1)).toBe('hooks.inline_thinking.enabled=true')
})

test('a preset that is neither true nor false is reported and read as false', async () => {
  const { io, asked, logged } = fakeSwitch('yes', says('no'))

  expect(await switchIsOn(io)).toBe(false)
  expect(asked[1]?.at(-1)).toBe('hooks.inline_thinking.enabled=false')
  expect(logged).toEqual(['INLINE_THINKING_DEFAULT is "yes", neither true nor false; treated as false'])
})

test('a policy or config file that does not parse turns it off, and says so', async () => {
  const stderr = 'config.py: /work/app/.agents/config.json is unreadable (Expecting value); every key in it falls back to its default\n'
  const { io, logged } = fakeSwitch('true', { exitCode: 0, stdout: 'yes\n', stderr })

  expect(await switchIsOn(io)).toBe(false)
  expect(logged).toEqual([`off in /work/app: ${stderr.trim()}`])
})

test('outside git the session folder decides; a submodule decides for itself', async () => {
  const outside = fakeSwitch('true', says('yes'), {
    exitCode: 128,
    stdout: '',
    stderr: 'fatal: not a git repository (or any of the parent directories): .git\n',
  })
  await switchIsOn(outside.io)
  expect(outside.asked[1]?.[2]).toBe('/work/app/.claude/worktrees/x/.agents/config.json')

  const submodule = fakeSwitch('true', says('yes'), {
    exitCode: 0,
    stdout: '/work/super/.git/modules/app\n/work/super/app\n',
    stderr: '',
  })
  await switchIsOn(submodule.io)
  expect(submodule.asked[1]?.[2]).toBe('/work/super/app/.agents/config.json')
})

test('git failing for any other reason fails loudly', async () => {
  const { io } = fakeSwitch('true', says('yes'), {
    exitCode: 128,
    stdout: '',
    stderr: "fatal: detected dubious ownership in repository at '/work/app'\n",
  })

  await expect(switchIsOn(io)).rejects.toThrow(/git cannot place .*dubious ownership/)
})

test('an unreadable answer from config.py fails loudly', async () => {
  const { io } = fakeSwitch('true', says('maybe'))

  await expect(switchIsOn(io)).rejects.toThrow(/config.py answered "maybe"/)
})

function seedAnchors(on: On, value: Record<string, string[]>) {
  on('state.get', () => ({ value: { value, version: 1 } }))
  // Stands for the engine's own row.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    const row = h(Text, {}, 'engine row')
    if (row === null || row === undefined || typeof row === 'string') throw new Error('h drew no element')
    return row
  })
}

const TOOL_ROW = {
  plugin: 'inline-thinking',
  component: 'ToolUse',
  requestId: 'toolu_1',
  surface: 'terminal',
  props: {
    tool_use_id: 'toolu_1',
    tool: 'Bash',
    input: { command: 'ls' },
    isRunning: false,
    isErrored: false,
    isInterrupted: false,
  },
} as const

test('the collapsed view draws the summary above the tool row', async ($, on) => {
  seedAnchors(on, { 'tool:toolu_1': ['The log names the failing step.'] })
  const ui = await $.ui.mount({ ...TOOL_ROW, props: { ...TOOL_ROW.props, isExpanded: false } })

  expect((await ui.find({ type: 'Text', text: /^∴/ }))?.text).toBe('∴ ')
  expect((await ui.find({ type: 'Text', text: /failing step/ }))?.text).toBe('The log names the failing step.')
  expect((await ui.find({ type: 'Text', text: /engine row/ }))?.text).toBe('engine row')
  await ui.unmount()
})

test('the collapsed view draws a later summary below the call result', async ($, on) => {
  seedAnchors(on, { 'after-tool:toolu_1': ['Deciding what to report.'] })
  const ui = await $.ui.mount({
    plugin: 'inline-thinking',
    component: 'ToolResult',
    requestId: 'toolu_1',
    surface: 'terminal',
    props: { tool_use_id: 'toolu_1', tool: 'Bash', output: { stdout: 'ok' }, isErrored: false, isExpanded: false },
  })

  expect((await ui.find({ type: 'Text', text: /what to report/ }))?.text).toBe('Deciding what to report.')
  await ui.unmount()
})

test('the expanded view leaves the row to the engine', async ($, on) => {
  seedAnchors(on, { 'tool:toolu_1': ['The log names the failing step.'] })
  const ui = await $.ui.mount({ ...TOOL_ROW, props: { ...TOOL_ROW.props, isExpanded: true } })

  expect(await ui.find({ type: 'Text', text: /∴/ })).toBe(undefined)
  expect((await ui.find({ type: 'Text', text: /engine row/ }))?.text).toBe('engine row')
  await ui.unmount()
})

test('a collapsed group of calls draws the summaries before and after its calls', async ($, on) => {
  seedAnchors(on, { 'tool:toolu_a': ['Both files are needed.'], 'after-tool:toolu_b': ['They agree.'] })
  const call = { tool: 'Read', input: {}, isRunning: false, isErrored: false, isInterrupted: false }
  const ui = await $.ui.mount({
    plugin: 'inline-thinking',
    component: 'ToolGroup',
    surface: 'terminal',
    props: {
      calls: [{ ...call, tool_use_id: 'toolu_a' }, { ...call, tool_use_id: 'toolu_b' }],
      isActive: false,
      isExpanded: false,
    },
  })

  expect((await ui.find({ type: 'Text', text: /files are needed/ }))?.text).toBe('Both files are needed.')
  expect((await ui.find({ type: 'Text', text: /agree/ }))?.text).toBe('They agree.')
  await ui.unmount()
})

test('a collapsed prompt row draws the summary that followed it, an expanded one does not', async ($, on) => {
  seedAnchors(on, { [promptKey('check the build')]: ['Plan: read the log first.'] })
  const row = (isExpanded: boolean) => ({
    plugin: 'inline-thinking',
    component: 'UserMessage',
    surface: 'terminal',
    props: { text: 'check the build', origin: { kind: 'composer' }, isExpanded },
  }) as const

  const collapsed = await $.ui.mount(row(false))
  expect((await collapsed.find({ type: 'Text', text: /read the log/ }))?.text).toBe('Plan: read the log first.')
  await collapsed.unmount()

  const expanded = await $.ui.mount(row(true))
  expect(await expanded.find({ type: 'Text', text: /∴/ })).toBe(undefined)
  await expanded.unmount()
})

test('a reply row draws the summary between it and the reply before', async ($, on) => {
  seedAnchors(on, { [textKey('One more note.')]: ['A second thought between replies.'] })
  const ui = await $.ui.mount({
    plugin: 'inline-thinking',
    component: 'AssistantMessage',
    surface: 'terminal',
    props: { text: 'One more note.', isFirstOfReply: true },
  })

  expect((await ui.find({ type: 'Text', text: /second thought/ }))?.text).toBe('A second thought between replies.')
  await ui.unmount()
})

test('a new prompt that repeats an earlier one makes its summary stop drawing at once', async ($, on) => {
  const written: unknown[] = []
  on('state.get', () => ({
    value: { value: { [promptKey('yes')]: ['Weighing the first yes.'], 'tool:toolu_1': ['Kept.'] }, version: 1 },
  }))
  on('state.set', (_, e) => {
    written.push(e.value)
    return { value: { isSet: true, version: 2 } }
  })

  // Stands for the engine taking the prompt.
  on('prompt.submit', (_, e) => ({ text: e.text }))

  await $.prompt.submit({ text: 'yes', wait: false, origin: { kind: 'composer' } })

  expect(written).toEqual([{ 'tool:toolu_1': ['Kept.'] }])
})

test('a new prompt that repeats nothing leaves the summaries alone', async ($, on) => {
  const written: unknown[] = []
  on('state.get', () => ({ value: { value: { [promptKey('yes')]: ['Weighing the first yes.'] }, version: 1 } }))
  on('state.set', (_, e) => {
    written.push(e.value)
    return { value: { isSet: true, version: 2 } }
  })

  // Stands for the engine taking the prompt.
  on('prompt.submit', (_, e) => ({ text: e.text }))

  await $.prompt.submit({ text: 'run the tests', wait: false, origin: { kind: 'composer' } })

  expect(written).toEqual([])
})
