---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree in **rounds**. The **frontier** is every decision whose prerequisites are already settled: the questions you can ask _now_ without guessing at answers you haven't heard yet. Ask the whole frontier in one round, each question with your recommended answer. Then wait for the user's answers before the next round.

Ask a round through the host's question tool where it has one (in Claude Code, `AskUserQuestion`); otherwise ask in plain prose. Give every question:

- the decision and why it matters now, in plain sentences that read cold, with the facts that bear on it;
- two to four options in all, within the tool's limits, each saying what it concretely changes;
- your recommended answer as the first option, marked as recommended, with its reason;
- unless the options exhaust the space, a last option to explore others.

Put facts that several questions share in a short message before the round; each question's own context goes in its question text and option descriptions. When the tool caps how many questions one call carries, a round spans consecutive calls.

Choosing to explore keeps the question open: widen the option set from the code, prior art, and how others solve the problem, dispatching a sub-agent for the facts, and bring the wider set back in the next round. A free-text answer always stands in place of any option.

Without a question tool, number the questions and end each with your recommendation. In either form, use no emoji or decorative markers.

Each round the user answers reshapes the tree: settled decisions push the frontier outward and unblock questions that depended on them. Recompute the frontier and ask the next round. A question whose answer depends on another question still open in this round belongs to a _later_ round, not this one.

Finding _facts_ is your job, never the user's. When a frontier question needs a fact from the environment (filesystem, tools, etc.), dispatch a sub-agent to find it; don't ask the user for anything you could look up yourself. Don't block on it: a running exploration is an unsettled prerequisite, so only the questions downstream of it wait for the sub-agent to report; ask the rest of the frontier now. The _decisions_ are the user's: put each to them and wait.

The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not act on it until the user confirms you have reached a shared understanding.
