// Row 4 of the band: this task's own state, which no status line carries.
// Pure: no `$`. The test-runner pattern and the per-task counters follow
// ponytail's band (MIT, hooks/band/metrics.ts; .agents/licenses records it).

export type Tests = 'none' | 'pass' | 'fail' | 'stale'

/** Removed definitions still called: a count, or a check that failed. */
export type Callers = { kind: 'none' } | { kind: 'open'; sites: number; names: readonly string[] } | { kind: 'failed' }

export type Task = {
  /** The session cost when the task began and after its last turn, in USD. */
  readonly startCost: number | undefined
  readonly lastCost: number | undefined
  readonly turnCosts: readonly number[]
  readonly turns: number
  readonly busyMs: number
  readonly tests: Tests
  /** Absolute paths of the .py files the task edited. */
  readonly editedPy: readonly string[]
  readonly callers: Callers
}

export const NEW_TASK: Task = {
  startCost: undefined,
  lastCost: undefined,
  turnCosts: [],
  turns: 0,
  busyMs: 0,
  tests: 'none',
  editedPy: [],
  callers: { kind: 'none' },
}

// A runner, as the words that start a simple command once its launchers are gone.
const RUNNER =
  /^(?:pytest|jest|vitest|rspec|phpunit|(?:npm|pnpm)(?: run)? test(?:[:.-][\w:.-]*)?|yarn test(?:[:.-][\w:.-]*)?|bun test|go test|cargo test|mvn test|gradle test|dotnet test|node --test|deno test|make test|claude plugin test|(?:bash |sh )?(?:\S*\/)?\.agents\/(?:suite|check-all|test-[\w.-]+)\.sh|python3? (?:\S*\/)?\.agents\/test-[\w.-]+\.py)(?: |$)/

// uv run options that take the next word as their value.
const UV_VALUE = new Set(['--with', '--with-requirements', '--with-editable', '--python', '-p', '--project', '--directory', '--extra', '--group', '--package', '--env-file', '--index', '--default-index', '--script'])

/**
 * The simple command's words with what runs it dropped: assignments, `time`,
 * `nice`, `command`, `env`, `timeout <n>`, `uv run [options]`, `npx`,
 * `pnpm exec` and `python -m`. `command -v` and its kin run nothing: no words.
 */
function launched(words: readonly string[]): readonly string[] {
  let w = words
  for (;;) {
    const [first = '', second = ''] = w
    if (/^[A-Za-z_]\w*=/.test(first)) w = w.slice(1)
    else if (first === 'time') w = w.slice(second === '-p' ? 2 : 1)
    else if (first === 'nice') w = w.slice(second === '-n' ? 3 : /^-\d+$/.test(second) ? 2 : 1)
    else if (first === 'command') {
      if (second.startsWith('-') && second !== '-p') return []
      w = w.slice(second === '-p' ? 2 : 1)
    } else if (first === 'env') {
      w = w.slice(1)
      while (w[0]?.startsWith('-') === true) w = w.slice(w[0] === '-u' ? 2 : 1)
    } else if (first === 'timeout') {
      w = w.slice(1)
      while (w[0]?.startsWith('-') === true) w = w.slice(w[0] === '-s' || w[0] === '-k' ? 2 : 1)
      w = w.slice(1)
    } else if (first === 'uv' && second === 'run') {
      w = w.slice(2)
      while (w[0]?.startsWith('-') === true) w = w.slice(!w[0].includes('=') && UV_VALUE.has(w[0]) ? 2 : 1)
    } else if (first === 'npx') {
      w = w.slice(1)
      while (w[0]?.startsWith('-') === true) w = w.slice(w[0] === '-p' || w[0] === '--package' ? 2 : 1)
    } else if (first === 'pnpm' && second === 'exec') w = w.slice(2)
    else if ((first === 'python' || first === 'python3') && second === '-m') w = w.slice(2)
    else return w
  }
}

/** Whether one simple command starts a runner. */
const startsRunner = (words: readonly string[]) => RUNNER.test(launched(words).join(' '))

type Piece = { words: string[]; after: string }

/**
 * The command cut into simple commands at its operators outside quotes, each
 * as its words (quotes removed) and the operator after it; a `#` that starts
 * a word outside quotes comments out the rest of its line. `isOpen` is true
 * when a quote is still open at the end.
 */
function pieces(command: string): { cut: Piece[]; isOpen: boolean } {
  const cut: Piece[] = []
  let words: string[] = []
  let word: string | undefined
  let quote = ''
  const endWord = () => {
    if (word !== undefined) words.push(word)
    word = undefined
  }
  for (let i = 0; i < command.length; i += 1) {
    const char = command[i] ?? ''
    if (quote !== '') {
      if (char === quote) quote = ''
      else if (char === '\\' && quote === '"') {
        word = (word ?? '') + (command[i + 1] ?? '')
        i += 1
      } else word = (word ?? '') + char
      continue
    }
    if (char === '"' || char === "'") {
      quote = char
      word = word ?? ''
      continue
    }
    if (char === '\\') {
      // A backslash before a newline continues the line: neither is a character.
      if (command[i + 1] === '\n') {
        i += 1
        continue
      }
      word = (word ?? '') + (command[i + 1] ?? '')
      i += 1
      continue
    }
    if (char === '#' && word === undefined) {
      while (i + 1 < command.length && command[i + 1] !== '\n') i += 1
      continue
    }
    if (char === ' ' || char === '\t') {
      endWord()
      continue
    }
    // `2>&1`, `&>file` and `>|file` are redirections, not operators.
    const before = command[i - 1] ?? ''
    const redirect = (char === '&' && (before === '>' || before === '<' || command[i + 1] === '>')) || (char === '|' && before === '>')
    const two = command.slice(i, i + 2)
    const op = redirect
      ? ''
      : two === '&&' || two === '||' || two === '|&'
        ? two
        : char === ';' || char === '|' || char === '&' || char === '\n'
          ? char
          : ''
    if (op === '') {
      word = (word ?? '') + char
      continue
    }
    endWord()
    cut.push({ words, after: op })
    words = []
    i += op.length - 1
  }
  endWord()
  cut.push({ words, after: '' })
  // A trailing `;` or newline ends the command; it hands the status to nothing.
  while (cut.length > 1 && cut[cut.length - 1]?.words.length === 0) cut.pop()
  const last = cut[cut.length - 1]
  if (last !== undefined && (last.after === ';' || last.after === '\n')) last.after = ''
  return { cut, isOpen: quote !== '' }
}

/** The command inside one `( … )` that encloses it whole. */
function unwrapped(command: string): string {
  const trimmed = command.trim().replace(/[;\n\s]+$/, '')
  return trimmed.startsWith('(') && trimmed.endsWith(')') ? trimmed.slice(1, -1) : trimmed
}

/**
 * Whether the command's exit status is a test runner's: a runner in command
 * position whose status reaches the end, through `&&` alone. A runner piped
 * into another command (`pytest | tail`), sent to the background (`&`), or
 * followed by more after `;`, `||` or a newline leaves the status to something
 * else, and so does a runner word anywhere else (`uv pip install pytest`,
 * `rg jest`), in a comment, or a command whose quote never closes.
 */
export function isTestRun(command: string): boolean {
  const { cut, isOpen } = pieces(unwrapped(command))
  if (isOpen) return false
  const at = cut.findLastIndex(piece => startsRunner(piece.words))
  if (at < 0) return false
  return cut.slice(at).every(piece => piece.after === '&&' || piece.after === '')
}

const CODE = /\.(py|[cm]?[jt]sx?|go|rs|rb)$/

/** Whether an edit to this file makes a passing test run stale. */
export const isCode = (file: string) => CODE.test(file)

/** A Bash command resolved: a test run sets the state, anything else keeps it. */
export function afterBash(task: Task, command: string, isError: boolean): Task {
  return isTestRun(command) ? { ...task, tests: isError ? 'fail' : 'pass' } : task
}

/** An Edit or Write landed: code after a test run makes it stale. */
export function afterEdit(task: Task, file: string): Task {
  const tests = isCode(file) && task.tests !== 'none' ? 'stale' : task.tests
  const editedPy = file.endsWith('.py') && !task.editedPy.includes(file) ? [...task.editedPy, file] : task.editedPy
  return { ...task, tests, editedPy }
}

/** A main-loop turn ended at this session cost after this many milliseconds. */
export function afterTurn(task: Task, cost: number | undefined, durationMs: number): Task {
  const before = task.lastCost ?? task.startCost
  // A cost below the one before means the engine started its ledger over.
  const turn = cost === undefined || before === undefined ? undefined : cost >= before ? cost - before : cost
  return {
    ...task,
    startCost: task.startCost ?? cost,
    lastCost: cost ?? task.lastCost,
    turnCosts: turn === undefined ? task.turnCosts : [...task.turnCosts, turn].slice(-20),
    turns: task.turns + 1,
    busyMs: task.busyMs + durationMs,
  }
}

/** `removed-callers.py --json` answered; anything else than its line is a failure. */
export function parseCallers(exitCode: number, stdout: string): Callers {
  if (exitCode !== 0) return { kind: 'failed' }
  let parsed: unknown
  try {
    parsed = JSON.parse(stdout)
  } catch {
    return { kind: 'failed' }
  }
  if (parsed === null || typeof parsed !== 'object') return { kind: 'failed' }
  const { names, sites } = parsed as { names?: unknown; sites?: unknown }
  if (!Array.isArray(names) || !names.every(name => typeof name === 'string') || typeof sites !== 'number') return { kind: 'failed' }
  return sites === 0 ? { kind: 'none' } : { kind: 'open', sites, names }
}

/** `3s`, `4m 10s`, `1h 12m`. */
export function elapsed(ms: number): string {
  const secs = Math.round(ms / 1000)
  if (secs < 60) return `${secs}s`
  const mins = Math.floor(secs / 60)
  if (mins < 60) return `${mins}m ${secs % 60}s`
  return `${Math.floor(mins / 60)}h ${mins % 60}m`
}

export const usd = (value: number) => `$${value.toFixed(2)}`

/** The task's cost so far: the session cost now less the cost it began at. */
export function taskCost(task: Task, costNow: number | undefined): number | undefined {
  if (costNow === undefined) return undefined
  return task.startCost === undefined || costNow < task.startCost ? costNow : costNow - task.startCost
}

export function callersText(callers: Callers): string | undefined {
  switch (callers.kind) {
    case 'none':
      return undefined
    case 'open':
      return `${callers.sites} callers open`
    case 'failed':
      return 'callers ?'
    default: {
      const never: never = callers
      throw new Error(`unknown callers state ${JSON.stringify(never)}`)
    }
  }
}

/** The task as Markdown, for the Copy button. */
export function markdown(task: Task, fields: { project: string; model: string; session: string; costNow: number | undefined }): string {
  const cost = taskCost(task, fields.costNow)
  const last = task.turnCosts[task.turnCosts.length - 1]
  const rows: [string, string][] = [
    ['Project', fields.project],
    ['Model', fields.model || '–'],
    ['Cost', cost === undefined ? '–' : `${usd(cost)}${last === undefined ? '' : ` · last turn ${usd(last)}`}`],
    ['Turns', String(task.turns)],
    ['Agent time', elapsed(task.busyMs)],
    ['Tests', task.tests === 'none' ? 'not run' : task.tests],
    ['Callers open', callersText(task.callers) ?? 'none'],
    ['Session', `\`${fields.session}\``],
  ]
  const cell = (text: string) => text.replace(/\|/g, '\\|')
  return ['## Task', '', '| | |', '|---|---|', ...rows.map(([key, value]) => `| ${key} | ${cell(value)} |`)].join('\n')
}
