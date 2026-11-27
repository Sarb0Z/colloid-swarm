import { expect, test } from 'claude-code/testing'

import { merge, parseGit, stripRows } from '../hooks/strip'
import type { Git } from '../hooks/strip'
import { CAPTURES } from './golden/strip'
import type { Capture } from './golden/strip'

// Every capture the bash strip drew is the expected value; the inputs it saw
// (git's and readout.py's real answers) are replayed into the port.

function gitOf(capture: Capture): Git | null {
  const status = capture.git?.['git status --porcelain=v2 --branch']
  if (status === undefined || status.exitCode !== 0) return null
  return parseGit(status.stdout, capture.git?.['git rev-parse --short HEAD']?.stdout ?? '')
}

function readoutsOf(capture: Capture): string | null {
  const answer = capture.readouts?.answer
  if (answer === undefined || answer === null) return null
  return answer.exitCode === 0 ? answer.stdout.replace(/\n+$/, '') : 'readouts: reader failed'
}

const isEmail = (capture: Capture) => capture.name.startsWith('email')

test('the port draws every capture the strip drew, run for run', async () => {
  const compared = CAPTURES.filter(capture => !isEmail(capture))
  expect(compared.length).toBe(49)
  for (const capture of compared) {
    const rows = stripRows(capture.status, capture.env, gitOf(capture), capture.now, readoutsOf(capture))
    expect(rows, capture.name).toEqual(capture.rows.map(merge).filter(row => row.length > 0))
  }
})

test('a badge name holding an @ is cut there, and keeps its colour', async () => {
  for (const capture of CAPTURES.filter(isEmail)) {
    const [badge] = stripRows(capture.status, capture.env, null, capture.now, null)[0] ?? []
    expect(badge?.text, capture.name).not.toContain('@')
    expect(badge?.color, capture.name).toBe(capture.rows[0]?.[0]?.color)
  }
  const [profile, folder] = CAPTURES.filter(isEmail).map(c => stripRows(c.status, c.env, null, c.now, null)[0]?.[0]?.text)
  expect(profile).toBe('● ME')
  expect(folder).toBe('● A')
})

test('a profile name the @ cut empties gives way to the folder name, and to no badge without one', async () => {
  const named = stripRows(
    { transcript_path: '/h/.claude-guest/projects/p/s.jsonl', workspace: { current_dir: '/w/app' } },
    { HOME: '/h', CLAUDE_PROFILE: '@corp' },
    null,
    0,
    null,
  )[0]?.[0]
  expect(named).toEqual({ text: '● GUEST', color: '#bb9af7', bold: true })
  const [first] = stripRows({ workspace: { current_dir: '/w/app' } }, { HOME: '/h', CLAUDE_PROFILE: '@corp' }, null, 0, null)[0] ?? []
  expect(first?.text).toBe(' app')
})
