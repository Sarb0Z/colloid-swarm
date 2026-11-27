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

const TEST_COMMAND =
  /\b(npm (run )?test|pnpm (run )?test|yarn test|bun test|npx (jest|vitest)|jest|vitest|pytest|python3? -m pytest|go test|cargo test|mvn test|gradle test|rspec|phpunit|dotnet test|node --test|deno test|make test)\b/

/** Whether a Bash command runs a test runner. */
export const isTestCommand = (command: string) => TEST_COMMAND.test(command)

const CODE = /\.(py|[cm]?[jt]sx?|go|rs|rb)$/

/** Whether an edit to this file makes a passing test run stale. */
export const isCode = (file: string) => CODE.test(file)

/** A Bash command resolved: a test run sets the state, anything else keeps it. */
export function afterBash(task: Task, command: string, isError: boolean): Task {
  return isTestCommand(command) ? { ...task, tests: isError ? 'fail' : 'pass' } : task
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
