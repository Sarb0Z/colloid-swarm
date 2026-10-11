---
name: grill-me
description: Runs the grilling interview and the domain-modeling discipline together, so a plan is stress-tested while its vocabulary and decisions are written down. Use when the operator types "/grill-me", asks to be grilled while building a domain model, or a critical Build or Spec reaches its grilling step.
---

# Grill me

Fuse two skills into one session:

1. Read `.agents/skills/grilling/SKILL.md` and `.agents/skills/domain-modeling/SKILL.md` in full before the first question.
2. Interview in `grilling`'s rounds: each round puts the whole frontier of the design tree through the host's question tool, every question carrying a recommended answer.
3. Between rounds, apply `domain-modeling`: challenge every term the answers introduce against an edge-case scenario, and write each settled term to `GLOSSARY.md` and each settled decision to `.agents/decisions.md` the moment it crystallises, not at the end.
4. End when the frontier is empty, reporting the decisions recorded, the glossary terms added or changed, and the branches the operator deferred.
