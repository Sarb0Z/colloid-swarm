# Handoff: the design session for mobile sync (unit 3, phone alerts)

## Objective

Design, with the operator, the phone link of the iTerm2 console: unit 3 of
`docs/notes/2026-11-15-iterm2-review-and-status-spec.md`. The operator wants
it designed carefully, because it is likely to become the base of later
features. The spec's unit 3 is a starting draft, not the agreed design. Do no
build before the operator approves the design.

Workflow: Spec. Stakes: critical. Unit 3 changes hook files and the hook
registry, and it sends to the operator's phone.

## Current state

- Units 1, 2 and 4 of the console are built, on origin/main at `1a05fd5`.
  The operator approved units 1 and 2. Unit 4's open item is probe P7's
  in-app rename followed by a relaunch.
- Unit 3 has no code. Its draft (spec, "Unit 3: Phone alerts") sends one
  alert for each new open gate (a `needs_confirmation:` line or a question).
  It removes duplicates by the gate's key, waits 5 s before the alert, and
  logs once when no phone is paired.
- No phone is paired: the iTerm2 preferences hold no companion keys
  (2026-11-17).

## Evidence to read first

1. `.agents/knowledge/research/2026-11-15-iterm2-buddy-mobile-sync.md`: what
   iTerm2 Buddy carries each way, its encryption, what a script can reach, the
   alternatives for two-way control (Claude Code Remote Control and channels,
   ntfy, Pushover), and the open probe questions. Main finding: a script
   reaches only a one-way slice. It can send an alert, and nothing the phone
   sends reaches a script or a hook.
2. The spec: rulings R11 (alert text: private route first, else no details),
   R12 (every open gate, always) and R16 (the unit's approval covers its
   sends); fact E7 (`it2 notify` sends plain text through Apple; trigger
   alerts send a content-free wake-up); probe P6 (can a hook fire the private
   route); acceptance 14-17.
3. `.agents/decisions.md`, entry `prompt-pane-through-lead`: an entry started
   in the Code Review pane reaches the tab's lead as a cross-session message,
   never through its input line. The ruling covers the pane only. A two-way
   phone link would need its own ruling, and this one is the precedent.
4. Unit 2's attention policy, `.agents/hooks/lib/iterm_attention.py`: it
   already calculates the open gate that an alert would carry. The breadcrumb
   "The sidebar hook gives up on one timed-out `it2` call" applies to any
   alert sent from it.

## Decisions for the session

Ask them one at a time, after the research has been re-checked:
- Scope: alerts only (the draft), or a two-way link. A two-way link has the
  phone answer gates or start prompts, and it needs a route other than
  Buddy's script slice.
- Route: Buddy's private route (needs P6) against `it2 notify` (plain text)
  against a self-hosted channel. Compare encryption, cost and lock-in.
- What an alert names: the project and the gate, or no details.
- What later features the base must carry, so that its data shape is chosen
  once.

## Limitations

- P6 needs a paired phone, and only the operator can pair one (iTerm2 ›
  Companion Device Settings: a QR code and a six-digit code).
- The device policy forces every session to the default permission mode
  (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`), so paths that need bypass mode
  cannot be tested on this Mac.
- GitHub Actions does not start jobs until the account's billing is fixed.
  The local `.agents/suite.sh` is the only check that runs.

## Remaining gates outside this unit

- contabo-hop: three of the four Claude accounts have no login, and `claudew`
  holds the personal login (sales@claims-org.example) where it should hold the work
  login (info@food-app.com.au). The operator signs in.
- contabo-hop: why the server tabs closed after the Mac woke on 2026-11-17 is
  not known. The next real sleep, with the et client log under `/private/tmp`
  read afterwards, decides it (`~/.config/docs/TERMINAL-SPEC.md`, Unit 5).
- Session colloid-swarm-2e still holds the server setup folder by its own
  message. The operator gave it back to the lead on 2026-11-17, and 2e has not
  been told.

## Next action

Read the four sources above, then open the design session with the operator.
The first question is the scope one, with each option's trade-off. No
authorization is needed for research. A send to the phone, or any change to
the hook registry, needs the operator's OK on the design.
