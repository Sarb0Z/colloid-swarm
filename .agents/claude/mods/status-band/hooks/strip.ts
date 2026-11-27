// Rows 1 to 3 of the band: the bash status strip's segments, colours and order,
// drawn from the status JSON Claude Code pipes to its statusLine command. Pure:
// no `$`, so the golden captures of the strip test it directly.
//
// Where the strip relied on a shell rule, the rule is spelled out here: jq's
// `x // ""` (null and false read as empty), bash's `${x%.*}` (a number cut at
// its last dot), integer division, and printf's `%.1f`, which rounds an exact
// tie to even where JavaScript's toFixed rounds it up.

/** One stretch of text in one colour and weight; null is the terminal's own. */
export type Run = { text: string; color: string | null; bold: boolean }

/** What git says about the session's folder; null outside a work tree. */
export type Git = { branch: string; dirty: number; ahead: number; behind: number }

/** The variables the badge reads. */
export type Profile = { HOME?: string; CLAUDE_PROFILE?: string; CLAUDE_CONFIG_DIR?: string }

// TokyoNight Night, as the strip drew it.
export const FG = '#c0caf5'
export const DIM = '#565f89'
export const BLUE = '#7aa2f7'
export const CYAN = '#7dcfff'
export const MAG = '#bb9af7'
export const GREEN = '#9ece6a'
export const YEL = '#e0af68'
export const ORANGE = '#ff9e64'
export const RED = '#f7768e'

const SEP: Run = { text: '  ', color: DIM, bold: false }

type Json = Record<string, unknown>

function at(value: unknown, ...path: string[]): unknown {
  let here = value
  for (const key of path) {
    if (here === null || typeof here !== 'object' || Array.isArray(here)) return undefined
    here = (here as Json)[key]
  }
  return here
}

/** jq's `(v // "" | tostring)`: null, absent and false are empty. */
function s(value: unknown): string {
  if (value === undefined || value === null || value === false) return ''
  if (typeof value === 'string') return value
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  return JSON.stringify(value)
}

/** bash's `${x%.*}` read as an integer: the text before its last dot. */
function int(text: string): number {
  const dot = text.lastIndexOf('.')
  const whole = Number.parseInt(dot < 0 ? text : text.slice(0, dot), 10)
  return Number.isNaN(whole) ? 0 : whole
}

/** printf '%.1f' of n / 1e6: the double's exact value, an exact tie to even. */
function millions(n: number): string {
  // n / 1e6 is an exact tie in tenths only when it is an odd number of quarters.
  if (n % 500000 === 250000) {
    const lower = Math.floor(n / 100000)
    const tenths = lower % 2 === 0 ? lower : lower + 1
    return `${Math.floor(tenths / 10)}.${tenths % 10}`
  }
  return (n / 1e6).toFixed(1)
}

/** The strip's `k`: thousands as `K`, from a million as `M` with one decimal. */
function k(text: string): string {
  const n = int(text)
  return n >= 1000000 ? `${millions(n)}M` : `${Math.trunc(n / 1000)}K`
}

function basename(path: string): string {
  const trimmed = path.replace(/\/+$/, '')
  if (trimmed === '') return path === '' ? '' : '/'
  return trimmed.slice(trimmed.lastIndexOf('/') + 1)
}

function two(n: number): string {
  return String(n).padStart(2, '0')
}

/**
 * The badge: CLAUDE_PROFILE, else the name of a non-default config folder
 * (~/.claude-<name>) read from the transcript path, or from CLAUDE_CONFIG_DIR
 * when there is none. Magenta for a named folder, yellow otherwise. A name is
 * cut at an `@`, so the badge never names an email.
 */
export function badge(transcript: string, env: Profile): Run | undefined {
  const home = env.HOME ?? ''
  const named = `${home}/.claude-`
  let folder = ''
  if (transcript.startsWith(named) && transcript.indexOf('/', named.length) >= 0) {
    folder = transcript.slice(named.length, transcript.indexOf('/', named.length))
  } else if (transcript === '' && (env.CLAUDE_CONFIG_DIR ?? '').startsWith(named)) {
    folder = (env.CLAUDE_CONFIG_DIR ?? '').slice(named.length)
  }
  const label = ((env.CLAUDE_PROFILE ?? '') || folder).split('@')[0] ?? ''
  if (label === '') return undefined
  return { text: `● ${label.replace(/[a-z]+/g, low => low.toUpperCase())}`, color: folder === '' ? YEL : MAG, bold: true }
}

/** Rows 1 and 2, then row 3 when `readouts` holds a line to draw. */
export function stripRows(status: Json, env: Profile, git: Git | null, nowMs: number, readouts: string | null): Run[][] {
  const transcript = s(at(status, 'transcript_path'))
  const cwd = s(at(status, 'workspace', 'current_dir'))
  const added = s(at(status, 'cost', 'total_lines_added')) || '0'
  const removed = s(at(status, 'cost', 'total_lines_removed')) || '0'
  const prNum = s(at(status, 'pr', 'number'))
  const prState = s(at(status, 'pr', 'review_state'))
  const worktree = at(status, 'workspace', 'git_worktree')
  const wt = s(worktree === undefined || worktree === null || worktree === false ? at(status, 'worktree', 'name') : worktree)
  const sname = s(at(status, 'session_name'))
  const dur = s(at(status, 'cost', 'total_duration_ms'))
  const vim = s(at(status, 'vim', 'mode'))

  const one: Run[] = []
  const plain = (text: string) => one.push({ text, color: null, bold: false })
  const shown = badge(transcript, env)
  if (shown !== undefined) one.push(shown)
  if (cwd !== '') {
    if (shown !== undefined) one.push(SEP)
    one.push({ text: ` ${basename(cwd)}`, color: GREEN, bold: false })
    if (git !== null) {
      plain(' ')
      one.push({ text: ` ${git.branch}`, color: MAG, bold: false })
      if (git.dirty !== 0) plain(' '), one.push({ text: `●${git.dirty}`, color: YEL, bold: false })
      if (git.ahead !== 0) plain(' '), one.push({ text: `↑${git.ahead}`, color: CYAN, bold: false })
      if (git.behind !== 0) plain(' '), one.push({ text: `↓${git.behind}`, color: ORANGE, bold: false })
    }
  }
  if (added !== '0' || removed !== '0') {
    plain('   ')
    one.push({ text: `+${added}`, color: GREEN, bold: false })
    plain(' ')
    one.push({ text: `−${removed}`, color: RED, bold: false })
  }
  if (prNum !== '') {
    const [color, icon] =
      prState === 'approved' ? [GREEN, '✓'] : prState === 'changes_requested' ? [RED, '✗'] : prState === 'draft' ? [DIM, '◌'] : [BLUE, '○']
    one.push(SEP, { text: ` #${prNum} ${icon}`, color, bold: false })
  }
  if (wt !== '') one.push(SEP, { text: ` ${wt}`, color: CYAN, bold: false })
  if (sname !== '') one.push(SEP, { text: sname, color: DIM, bold: false })
  if (dur !== '' && int(dur) > 0) {
    const m = Math.trunc(int(dur) / 60000)
    one.push(SEP, { text: m >= 60 ? `󰔛 ${Math.trunc(m / 60)}h${two(m % 60)}m` : `󰔛 ${m}m`, color: DIM, bold: false })
  }
  if (vim !== '') one.push(SEP, { text: vim, color: BLUE, bold: true })

  const model = s(at(status, 'model', 'display_name'))
  const effort = s(at(status, 'effort', 'level'))
  const pct = s(at(status, 'context_window', 'used_percentage'))
  const ctxSize = s(at(status, 'context_window', 'context_window_size'))
  const usage = at(status, 'context_window', 'current_usage')
  const count = (key: string) => {
    const value = at(usage, key)
    return typeof value === 'number' ? value : 0
  }
  const ctxUsed = String(count('input_tokens') + count('cache_creation_input_tokens') + count('cache_read_input_tokens'))
  const h5 = s(at(status, 'rate_limits', 'five_hour', 'used_percentage'))
  const h5Reset = s(at(status, 'rate_limits', 'five_hour', 'resets_at'))
  const d7 = s(at(status, 'rate_limits', 'seven_day', 'used_percentage'))
  const style = s(at(status, 'output_style', 'name'))

  const second: Run[] = [{ text: model || '?', color: FG, bold: true }]
  const gap = () => second.push({ text: ' ', color: null, bold: false })
  if (effort !== '') gap(), second.push({ text: '⚡', color: DIM, bold: false }), gap(), second.push({ text: effort, color: FG, bold: false })
  if (s(at(status, 'thinking', 'enabled')) === 'true') gap(), second.push({ text: '󰧑', color: MAG, bold: false })
  if (s(at(status, 'fast_mode')) === 'true') gap(), second.push({ text: '󱐋fast', color: ORANGE, bold: false })
  if (pct !== '') {
    const p = int(pct)
    const filled = Math.min(Math.trunc((p * 10) / 100), 10)
    const color = p >= 85 ? RED : p >= 60 ? ORANGE : GREEN
    const bar = Array.from({ length: 10 }, (_, i) => (i < filled ? '━' : '┄')).join('')
    second.push(SEP, { text: bar, color, bold: false })
    gap()
    second.push({ text: k(ctxUsed), color, bold: false }, { text: `/${k(ctxSize || '200000')}`, color: DIM, bold: false })
  }
  const limit = (label: string, used: string, reset: string) => {
    const n = int(used)
    second.push(SEP, { text: label, color: DIM, bold: false })
    gap()
    second.push({ text: `${n}%`, color: n >= 90 ? RED : n >= 70 ? ORANGE : FG, bold: false })
    if (reset !== '') gap(), second.push({ text: `↻${reset}`, color: DIM, bold: false })
  }
  if (h5 !== '') {
    let left = ''
    if (h5Reset !== '') {
      const secs = Math.max(int(h5Reset) - Math.trunc(nowMs / 1000), 0)
      left = `${Math.trunc(secs / 3600)}h${two(Math.trunc((secs % 3600) / 60))}m`
    }
    limit('5h', h5, left)
  }
  if (d7 !== '') limit('7d', d7, '')
  if (style !== '' && style !== 'default') second.push(SEP, { text: `style:${style}`, color: DIM, bold: false })

  const rows = [one, second]
  if (readouts !== null && readouts !== '') {
    // The strip coloured the first readout and drew the rest in the terminal's
    // own colour, after each separator's reset.
    const [first = '', ...rest] = readouts.split('  ·  ')
    const third: Run[] = [{ text: first, color: FG, bold: false }]
    for (const part of rest) third.push(SEP, { text: part, color: null, bold: false })
    rows.push(third)
  }
  return rows.map(merge)
}

/** Adjacent runs of one colour and weight as one, empty runs dropped. */
export function merge(runs: readonly Run[]): Run[] {
  const out: Run[] = []
  for (const run of runs) {
    if (run.text === '') continue
    const last = out[out.length - 1]
    if (last !== undefined && last.color === run.color && last.bold === run.bold) {
      out[out.length - 1] = { ...last, text: last.text + run.text }
    } else {
      out.push(run)
    }
  }
  return out
}

/**
 * `git status --porcelain=v2 --branch` read as the strip's four commands
 * answered: the branch (a detached head's short id from `short`), the number
 * of changed and untracked paths, and the commits ahead of and behind the
 * upstream, 0 and 0 without one.
 */
export function parseGit(stdout: string, short: string): Git {
  let branch = ''
  let ahead = 0
  let behind = 0
  let dirty = 0
  for (const line of stdout.split('\n')) {
    if (line === '') continue
    if (!line.startsWith('# ')) {
      dirty += 1
      continue
    }
    const head = /^# branch\.head (.+)$/.exec(line)
    if (head?.[1] !== undefined) branch = head[1] === '(detached)' ? short.trim() : head[1]
    const ab = /^# branch\.ab \+(\d+) -(\d+)$/.exec(line)
    if (ab !== null) {
      ahead = Number(ab[1])
      behind = Number(ab[2])
    }
  }
  return { branch, dirty, ahead, behind }
}
