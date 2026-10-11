---
name: grill-me
description: Runs the grilling interview and the domain-modeling discipline together, so a plan is stress-tested while its vocabulary and decisions are written down. Use when the operator types "/grill-me", asks to be grilled while building a domain model, or a critical Build or Spec reaches its grilling step.
---

# Grill me

Run two skills as one session: the interview applies the pressure, and the domain model records what survives it. Apart, each fails the other's way — a grilling that writes nothing down settles its terms in a conversation the next session cannot read, and a glossary built without pressure records words nobody has tried to break.

1. Read `.agents/skills/grilling/SKILL.md` and `.agents/skills/domain-modeling/SKILL.md` in full before the first question; the first round already needs both.
2. Interview by `grilling`'s rounds: the whole frontier of the design tree per round, through the host's question tool, each question with a recommended answer.
3. Between rounds, apply `domain-modeling`: challenge every term the answers introduce, test it against an edge-case scenario, and write the settled term to `GLOSSARY.md` and any settled decision to `.agents/decisions.md` the moment it crystallises, not at the end. Every answered round reshapes the tree, and the next builds on the terms the last one settled; a term written down only at the end is written from a memory the interview has since bent.
4. End when the frontier is empty. Report the decisions recorded, the glossary terms added or changed, and the branches the operator deferred.
