import type { EngineInterface, Register } from 'claude-code'

// Where no permission prompt reaches the user (auto, bypassPermissions,
// dontAsk), guard-publish denies a publish outright. This mod asks the user in
// Claude Code's own question dialog, which reaches them in every mode, before
// the call runs. "Run it" writes a token for this one call, which
// guard-publish reads and turns its ask or deny into allow; every other hook
// still decides, and a deny among them wins. The mod never decides by itself
// whether a call publishes: it asks guard-publish, by argv, the same question
// the settings hook will.

const RUN = 'Run it'
const REFUSE = 'Refuse'
const HEADER = 'Publish'
const SHOWN = 600

type Decision = { readonly decision: string; readonly reason: string }

// guard-publish prints nothing on a call it lets through, or one PreToolUse
// envelope. Anything else is a defect the registration's catch reports.
function parseDecision(stdout: string): Decision | undefined {
  if (stdout.trim() === '') return undefined
  const envelope: unknown = JSON.parse(stdout)
  const output = typeof envelope === 'object' && envelope !== null && 'hookSpecificOutput' in envelope
    ? envelope.hookSpecificOutput : undefined
  if (typeof output !== 'object' || output === null
      || !('permissionDecision' in output) || typeof output.permissionDecision !== 'string'
      || !('permissionDecisionReason' in output) || typeof output.permissionDecisionReason !== 'string') {
    throw new Error(`guard-publish printed an unexpected envelope: ${stdout.slice(0, 200)}`)
  }
  return { decision: output.permissionDecision, reason: output.permissionDecisionReason }
}

// The repository root when the switch is on, else undefined. The canonical
// folder is <repo>/.agents/claude/mods/<name>, wherever the host link points.
async function switchedOnRepo($: EngineInterface): Promise<string | undefined> {
  const own = (await $.fs.stat($.plugin.root, { resolve: true })).realPath
  if (own === undefined) throw new Error(`cannot resolve ${$.plugin.root}`)
  const root = own.split(/[\\/]/).slice(0, -4).join('/')
  const switched = await $.process.run([
    'python3', `${root}/.agents/hooks/lib/config.py`, `${root}/.agents/config.json`,
    'hooks.publish_approval.enabled=true',
  ])
  const word = switched.stdout.trim()
  if (switched.exitCode !== 0 || (word !== 'yes' && word !== 'no')) {
    throw new Error(`config.py answered ${JSON.stringify(word)} (exit ${switched.exitCode}): ${switched.stderr.trim()}`)
  }
  return word === 'yes' ? root : undefined
}

export const register: Register = on => {
  // Settled on the first gated call rather than at session start, which a
  // plugin loaded with the session does not reliably see. A rejection stays,
  // so every later call reports it through the catch below.
  let settled: Promise<string | undefined> | undefined

  on('session.start', async ($, e, next) => {
    settled = undefined                // /clear or a resume re-reads the switch
    return next(e)
  })

  // The tools guard-publish reads. PowerShell exists only on Windows builds, so
  // a pattern rather than a list of names this build may not declare.
  on('tool.call', { tool: /^(?:Bash|PowerShell|Monitor|Artifact)$/ }, async ($, e, next) => {
    const repo = await (settled ??= switchedOnRepo($))
    if (repo === undefined) return next(e)
    const { tool, tool_use_id, agentId, ...tool_input } = e
    // permission_mode default: the question is whether the guard would ask a
    // person, whatever the session's mode turns that ask into.
    const verdict = await $.process.run(['python3', `${repo}/.agents/hooks/lib/guard-publish.py`, repo], {
      stdin: JSON.stringify({
        tool_name: tool, tool_input, tool_use_id, permission_mode: 'default',
        cwd: await $.session.cwd(), project_dir: repo,
      }),
    })
    if (verdict.exitCode !== 0) {
      $.ui.log(`${$.plugin.name}: guard-publish exited ${verdict.exitCode}: ${verdict.stderr.trim()}; the guard decides this call alone`)
      return next(e)
    }
    const decision = parseDecision(verdict.stdout)
    if (decision?.decision !== 'ask') return next(e)

    // "Run it" approves the whole call, so the user must see all of it. Quoting
    // makes newlines, carriage returns and escape sequences visible instead of
    // letting them push the real command out of view; a call too long to show
    // whole gets no dialog, and the guard decides alone.
    const subject = 'command' in tool_input && typeof tool_input.command === 'string'
      ? tool_input.command : JSON.stringify(tool_input)
    const shown = JSON.stringify(subject)
    if (shown.length > SHOWN) {
      $.ui.log(`${$.plugin.name}: the call is ${shown.length} characters quoted, over ${SHOWN}; the guard decides it alone`)
      return next(e)
    }
    const who = agentId === undefined ? 'The agent' : `Subagent ${agentId}`
    let answer: string
    try {
      answer = await $.ui.ask(
        `${who} wants to run a ${tool} call that the publish guard gates:\n\n${shown}\n\n${decision.reason}\n\nRun it?`,
        { options: [REFUSE, RUN], header: HEADER },
      )
    } catch (unanswered) {
      // Dismissed, resolved while the user was away (see the hook below), or
      // nobody to ask (claude -p): none is an answer, so the guard decides alone.
      $.ui.log(`${$.plugin.name}: no answer from the user (${String(unanswered)}); the guard decides this call alone`, { to: 'debug' })
      return next(e)
    }
    if (answer === REFUSE) {
      return { deny: `The user refused this call in the ${$.plugin.name} dialog. Do not retry it or work around it; ask the user what they want instead.` }
    }
    // Typed text under "Other" is not an approval; the guard decides alone.
    if (answer === RUN) await $.fs.write(`${repo}/.agents/.publish-approved-${tool_use_id}`, '')
    return next(e)
  }).catch(($, e, next) => {
    $.ui.log(`${$.plugin.name}: ${next.error.message}; the guard decides this call alone`)
    return next(e)
  })

  // $.ui.ask returns only a label, and the dialog can resolve itself after the
  // user has been idle (afkTimeoutMs). The dialog runs through this plugin's
  // other hooks, so this one turns such a result for its own dialog into a
  // refusal of the dialog, which makes $.ui.ask reject instead of approving.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const answered = await next(e)
    const ours = e.questions.length === 1 && e.questions[0]?.header === HEADER
    if (ours && answered.deny === undefined && answered.isError !== true && answered.result.afkTimeoutMs !== undefined) {
      return { deny: 'The publish dialog resolved while the user was away; that is not an approval.' }
    }
    return answered
  })
}
