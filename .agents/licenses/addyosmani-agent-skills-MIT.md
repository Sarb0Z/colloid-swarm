# addyosmani/agent-skills

Text in the file below is adapted from https://github.com/addyosmani/agent-skills
(branch `main`, commit `301b02b12bff98e4688e6984af6556802322bbde`) by Addy
Osmani, under the MIT License below. No upstream file is carried whole.

| Local file | Adapted text | Upstream path |
| --- | --- | --- |
| `rules/testing.md` | "Test behavior, not implementation details"; "Mock at system boundaries (database, network), not between internal functions"; "A test that never fails is as useless as a test that always fails"; the snapshot caution | `agents/test-engineer.md` |
| `rules/testing.md` | "Assert on the outcome of an operation"; DAMP over DRY in tests | `skills/test-driven-development/SKILL.md` |
| `rules/testing.md` | "Invert one condition the change adds (drop a negation, swap `&&` for `||`), run the suite, then restore the file from a copy." | `skills/code-review-and-quality/SKILL.md` |

Differences from the source: the lines are rephrased as invariants of one path
rule, the boundary list adds the clock and the filesystem, and the
inverted-condition check applies to each new test rather than to a reviewed
change.

## License

```text
MIT License

Copyright (c) 2025 Addy Osmani

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
