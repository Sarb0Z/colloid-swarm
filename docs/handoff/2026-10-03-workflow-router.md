# Workflow router

## Objective

Replace the single six-step "Workflow" in the root `AGENTS.md` with a router.
Each task gets the procedure that fits its kind and its stakes. The router and
the playbooks are plain files, so Codex and Kimi read them too; no mod is
needed.

## Direction from the operator (2026-10-03)

- "If you literally want the same thing every single time. It is stricly worse."
- "I don't always want hostile review when I have AI write code. A disposal
  script ... doesn't get the same treatment as code that needs to ship to prod."
- "So I can have some really heavy duty workflow for the important stuff."
- "then in other cases like the ones you found we come up with different
  workflows/playbooks"
- "its probably better to have the common 4 or 5 workflows separately and have
  system prompt route them to me"
- "you can keep all ten task types if they're unique, just have the common ones
  cached"

## Evidence

From `.agents/knowledge/research/2026-10-03-workflows-mined-from-sessions.md`:

- 473 Claude episodes fall into about ten workflow types.
- The six steps pay off only for feature builds, transplants and large scaffold
  changes, about 18% of episodes. Ask, ship and ops episodes (48%) need nothing
  past research.
- Docs and reports draw the most corrections. Deploy and ops draw the most
  challenges.
- The session-wrap question is the largest single source of user questions.

## Design: workflow and stakes

A task has a **workflow**, which says what kind of work it is, and **stakes**,
which say what a mistake costs. The workflow selects the steps, and the stakes
select how heavy each step is. "Stakes" is the term because "tier" already names
the model tiers in "Subagent Delegation" and the size tiers in `session-wrap`.
Critical stakes do not choose the model. The delegation table does.

### Ten workflows; the five common ones cached

The router in `AGENTS.md` lists all ten. The five common workflows carry their
steps inline, so they sit in the cached prompt prefix of every session. The
other five point to a playbook that the agent reads when it routes there.
Career-ops and personal tasks belong to their own repositories, not the carrier.

| Workflow | Mined types | Share | Where its steps live |
|---|---|---|---|
| Answer | Question, lookup, status readout | 18% | Inline |
| Ship | Commit, push, sync, merge to a branch, deploy, release | 15% | Inline |
| Operate | Infra, credentials, CI, servers, machine setup | 15% | Inline |
| Build | Feature build | 14% | Inline |
| Fix | Debug, incident, UI fix from a screenshot | 11% | Inline |
| Write | Docs, reports, EOD, assets | 9% | `.agents/playbooks/workflow-write.md` |
| Spec | Spec, plan, research, meeting intake | 8% | `.agents/playbooks/workflow-spec.md` |
| Scaffold | Scaffold edit, transplant | 4% | `.agents/playbooks/workflow-scaffold.md` |
| Verify | QA of a deployed or built thing | about 2% | `.agents/playbooks/workflow-verify.md` |
| Merge | Triage, test-merge and review of a pull request | about 2% | `.agents/playbooks/workflow-merge.md` |

The agent states the workflow and the stakes in one line of its first reply:
`Workflow: <name> · Stakes: <level>`. It repeats the line when either one
changes. The operator can override both. A task that fits no workflow goes to
the operator as a question.

### Stakes

The agent decides stakes by effect, from the paths a change touches and what
the change does. It does not decide them from where the output goes.

| Stakes | Rule |
|---|---|
| Disposable | Nothing is kept or shipped, and nothing writes outside the working tree or the scratch directory: a one-off analysis script, a probe, an answer. |
| Standard | It is kept in a repository and ships, and a mistake is reversible and cheap. |
| Critical | It touches production, money, auth, data that can be lost, a guard or gate hook, or a contract. A contract here is the root `AGENTS.md`, `.agents/AGENTS.md`, the playbooks and the hostile-review contract. |

- Any outward mutation, or any write to a live system, is never disposable. The
  Ship and Operate workflows have no disposable level, which closes the
  production-from-`/tmp` pattern recorded in `hosted-writes-need-committed-code`.
- Answer has no stakes.
- Scaffold notes and knowledge entries are standard. Guards, gates and the
  contract are critical.
- When unsure, take the higher level, as the contract says for high-stakes work
  today.
- The first line of root `AGENTS.md`, "Every change ships to production", is
  scoped to changes kept in a repository, so that disposable work is legitimate.

### Rules every workflow keeps

Today these rules sit inside the six steps. They move to a "Rules for every
workflow" section of `AGENTS.md`, so that removing the steps loses none of them:

- Research grounding: the `search-and-cite` and `market-researcher` routing, and
  "sweep the adjacent patterns; the named ones are the hypothesis".
- High-stakes classification, and naming the one claim that QA must reproduce
  independently.
- Evidence: tie every fix to observed evidence, stop and instrument after two
  failed fixes, simulate destructive or scarce operations and say what remains
  unverified.
- "Done means the user-facing surface completes the job".
- `qa-verifier` always runs for a high-stakes claim, and closes what it started.
- The pointer to `.agents/playbooks/hostile-review.md` as the reviewer contract,
  including the note that `.agents/eval/review-harness` grades against it.

Testing text: the current steps 4 and 5 ("implement, then test" and the QA step)
move unchanged into Build, Fix and Scaffold at every stakes level. The testing
write-up (`docs/handoff/2026-10-03-testing-writeup-inputs.md`) replaces that text
when it lands. This plan adds no testing rule.

### Human gates

The critical sequence adds gates where the operator decides. Today the contract
says "the task is the authorization ... do not ask" and "Do not stop at a plan".
So the router adds an explicit exception to "Verify with user" and "Persist to
completion" for these gates:

- Only the lead holds a gate. A subagent never asks the operator; it returns to
  the lead.
- An unattended run (auto mode, a background cell, a workloop lane) stops at the
  gate and reports. It never skips the gate.
- The "no code before the OK" gate uses host plan mode. Plan mode already blocks
  edits until the operator approves the plan. Whether that approval behaves the
  same in auto mode is unverified, and slice 2 probes it.

### Build

| Step | Disposable | Standard | Critical |
|---|---|---|---|
| Grill and model the domain (`grilling`, `domain-modeling`) | — | — | Yes |
| Plan, naming the claim QA must reproduce | — | Yes | Yes |
| AI hostile review of the plan | — | Yes | Yes |
| Operator review of the plan, and the OK to start coding (plan mode) | — | — | Yes |
| Implement and test (current step 4 text) | Run it once, for real | Yes | Yes |
| QA the named claim (current step 5 text) | — | When behavior is observable | Yes |
| Code review | — | One reviewer | Several reviewers, one axis each, as one round |
| Review of the code review | — | — | Yes |
| Make the safe changes | — | Yes | Yes |
| Walk the operator through each change that needs them | — | — | Yes |
| Commit along seams | — | As each chunk lands | As each chunk lands; the walk-through reviews committed changes, and its fixes fold in before push |

The review of the code review **labels** each finding as supported or
unsupported, with a reason. It never removes one. Every P0 or P1 it rejects goes
to the walk-through with that reason, so the operator sees every blocking
finding. This pass sits in `hostile-review.md` outside the fenced reviewer
contract, so `test-review-contract.sh` and the review harness stay valid. The
several reviewers count as one round under "Review a slice one time".

### The other inline workflows

| Workflow | Standard steps | What critical adds |
|---|---|---|
| Answer | Answer from observed state, and cite the command or file | — |
| Ship | Fetch before asserting; dry-run where the tool has one; one approval per outward action; verify the result where it runs | A rollback plan before the action |
| Operate | Back up first; keep production read-only until approved; write a runbook for every step the operator runs; keep the change in the repository | An operator review of the runbook |
| Fix | Reproduce; report the root and the proximate cause before the fix; then the Build steps from implement onward | Contain first; the operator's OK before the fix; the critical Build reviews |

The five playbook workflows follow the same table format in their files. Write
shows a format sample or the stored style first. Spec may end at the spec.
Scaffold always runs Build at critical stakes and propagates to satellites last.
Verify runs against the deployed environment. Merge holds the operator's
PR-merge procedure.

## Procedures to make into skills

The operator re-types these. Each becomes a skill or a script, not a contract
step:

- the PR merge: "test merge and full engine suite. Also review the code yourself
  before merging", pasted 8 times. The Merge workflow uses it;
- the EOD report in the operator's format;
- sync with remote;
- worklog updates;
- teardown;
- delegation defaults;
- TaxDrop's sample addresses, which belong to that satellite.

## Slices

Each slice works end to end before the next one starts.

1. **Done (`de1f830`, `60f642b`).** Vendor `grilling` and `domain-modeling` from `mattpocock/skills` (MIT) as
   one vendored commit. Include the sibling files that `domain-modeling` links,
   `GLOSSARY-FORMAT.md` (and not `ADR-FORMAT.md`, per decision 2). Record any fork (for example, the
   ADR rule) in each skill's `AGENTS.md`, and add the MIT notice to
   `.agents/licenses/`.
2. **The router, as one unit:**
   - The router section and the "Rules for every workflow" section in
     `AGENTS.md`, with the exceptions to "Verify with user" and "Persist to
     completion".
   - The five inline workflows and the five playbook files.
   - The review-of-the-review pass in `hostile-review.md`.
   - A probe of plan-mode approval in auto mode.
   - An operator command that runs `grilling` and `domain-modeling` together.
     The operator asked for "something like /grillme to help build a domain
     model". Upstream's `grill-with-docs` wrapper has that shape. Slice 1 did
     not carry it, because its description names ADRs.

   The six steps leave in the same commit, so no workflow is ever without a
   procedure.
3. **`session-wrap` reads the workflow and the stakes.**
   - It parses the last `Workflow: … · Stakes: …` line from the transcript
     (`transcript_path`), and asks as today when it finds none.
   - It asks only for Build, Spec and Scaffold at standard or critical stakes.
   - It drops its own hostile-review section when the workflow already reviewed
     the slice.
   - It ships with a firing test in `.agents/test-session-wrap.sh`.
4. **Skills for the re-typed procedures,** starting with the PR merge and the EOD
   report.

Before the next satellite sync, `merge-kit.py` must capture satellite-owned
paragraphs inside the replaced `## Workflow` section.
`~/Projects/Incura/clearclaim/AGENTS.md` holds one, its work-packet
serialization.

## Settled with the operator (2026-10-03)

1. **Routing.** The router picks the workflow and the stakes, states them in its
   first reply, and the operator overrides. The operator can also start a
   workflow by name, as with `/grill-me`.
2. **Glossary and ADRs.** Each product repository keeps a `GLOSSARY.md` as product
   documentation. Decisions stay in `decisions.md`, not in ADRs, so the vendored
   `domain-modeling` is a recorded fork that drops its ADR instructions and
   `ADR-FORMAT.md`.
3. **Commit timing.** Every stakes level commits as each chunk lands, critical
   included. The walk-through reviews committed changes, and its fixes fold into
   the commits they belong to before push. TaxDrop keeps "only when asked". The
   hooks need no change for this.
4. **Scaffold stakes.** Critical for guard and gate hooks and the contract files;
   standard for everything else in the scaffold.
