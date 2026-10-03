# mattpocock/skills

`.agents/skills/grilling/` and `.agents/skills/domain-modeling/` come from
https://github.com/mattpocock/skills (branch `main`, commit
`d81f3a183412e71a5b1e84ca21bc1a35eea03a60`) by Matt Pocock, under the MIT
License below.

| Local file | Upstream path |
| --- | --- |
| `grilling/SKILL.md` | `skills/productivity/grilling/SKILL.md` |
| `domain-modeling/SKILL.md` | `skills/engineering/domain-modeling/SKILL.md` |
| `domain-modeling/GLOSSARY-FORMAT.md` | `skills/engineering/domain-modeling/GLOSSARY-FORMAT.md` |

These upstream files are not carried:

- `skills/engineering/domain-modeling/ADR-FORMAT.md`. Decisions go to
  `.agents/decisions.md`, as the next list states.
- Each skill's `agents/openai.yaml`. It holds Codex display metadata, and Codex
  reads the `SKILL.md` frontmatter.
- The wrapper skills `grill-me` and `grill-with-docs`. Each one only invokes
  `grilling`, or `grilling` and `domain-modeling`, so `/grilling` starts the
  same interview.

`grilling/SKILL.md` and `domain-modeling/GLOSSARY-FORMAT.md` are byte-identical
to the source. `domain-modeling/SKILL.md` differs from the source in these ways:

- It records a decision as an entry in `.agents/decisions.md`, and not as an
  ADR under `docs/adr/`. It states the entry shape inline, because a
  satellite's copy of that file may not state it. It keeps the source's three
  tests for when a decision earns a record.
- Its description and both file-structure diagrams name `.agents/decisions.md`
  in place of `docs/adr/`. In a repository with several contexts, one
  `.agents/decisions.md` holds the decisions for every context.

## License

```text
MIT License

Copyright (c) 2026 Matt Pocock

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
