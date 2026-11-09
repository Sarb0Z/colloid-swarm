# Lenses

A rule says what must be true; a lens says where to look. The workflows name
the moment each section fires. Apply each lens the artifact can exhibit, and
name each one that changed the plan, the fix, or the findings, with what it
changed. A lens answer that enlarges scope is weighed under the root
Principles: Gall's Law and YAGNI decide whether the rewrite or the larger
abstraction is built now.

## Plan

Fires at the Build plan step, and when a spec is written at Standard or
Critical stakes.

- **What higher-level abstraction would make this entire problem disappear?**
  Catches machinery built for a problem that a different framing removes.
- **Reduce this problem to its irreducible constraints and rebuild it from
  zero.** Catches constraints inherited from the current shape rather than
  from the requirement.
- **Carve the problem at the joints.** Catches modules split by file, layer,
  or ticket instead of along the seams the domain already has.
- **What would a principal architect immediately rewrite before even starting
  this?** Catches building on a foundation the change will outgrow: make the
  change easy, then make the easy change.
- **Find every implicit state machine.** Catches flags, nullable fields, and
  status strings that combine into states no one designed.
- **Concession drift: you will get money pumped.** Lay the plan's trade-offs
  side by side: if each was accepted on its own and together they leave the
  work worse than where it started, one of them is wrong. Catches a run of
  reasonable concessions that adds up to an unreasonable plan.

## Stuck

Fires after two failed fixes, and whenever patches pile up around one defect.

- **Are you in a rabbit hole, duct-taping custom fixes together? Is there a
  native way of doing this that would be cleaner?** Catches hand-built
  workarounds for what the framework, platform, or library already provides.

## Review

Fires in the hostile reviewer's sweep, for a plan and for a diff.

- **Design the single test that breaks this design on day one.** Catches the
  load-bearing assumption nobody tested.
- **Find every implicit state machine.** Can a flow skip a step, go
  backwards, reach an invalid state, or replay a completed run? If step 2 of 3
  fails, is step 1 rolled back? In a diff, look for a new flag or status that
  interacts with an existing one.
- **You will get money pumped.** Find the cycle of individually allowed
  actions (refund and reuse, cancel and resubscribe, retry, transfer) that
  leaves the system or its owner worse off at the end. Catches exploitable
  cycles in pricing, credits, quotas, and state transitions.
