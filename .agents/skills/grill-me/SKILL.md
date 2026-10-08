---
name: grill-me
description: Runs the grilling interview and the domain-modeling discipline together, so a plan is stress-tested while its vocabulary and decisions are written down. Use when the operator types "/grill-me", asks to be grilled while building a domain model, or a critical Build or Spec reaches its grilling step.
---

# Grill me

Run two skills as one session:

1. Read `.agents/skills/grilling/SKILL.md` and `.agents/skills/domain-modeling/SKILL.md` in full before the first question.
2. Interview by `grilling`'s rounds: the whole frontier of the design tree per round, through the host's question tool, each question with a recommended answer.
3. Between rounds, apply `domain-modeling`: challenge every term the answers introduce, test it against an edge-case scenario, and write the settled term to `GLOSSARY.md` and any settled decision to `.agents/decisions.md` the moment it crystallises, not at the end.
4. End when the frontier is empty. Report the decisions recorded, the glossary terms added or changed, and the branches the operator deferred.
