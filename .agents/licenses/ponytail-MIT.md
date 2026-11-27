# DietrichGebert/ponytail

Code in the file below is adapted from https://github.com/DietrichGebert/ponytail
(branch `main`, commit `ebd8654c2c627f721eb8f9c0d1bd4090a29f9e10`) by
DietrichGebert, under the MIT License below. No upstream file is carried whole.

| Local file | Adapted code | Upstream path |
| --- | --- | --- |
| `claude/mods/status-band/hooks/task.ts` | The test-runner pattern (`TEST_COMMAND`), pass or fail from a Bash test run and stale after a later code edit, and the per-task counters: turn cost as the difference from the cost before, a cost below it read as a ledger that started over, agent time as the sum of turn durations | `hooks/band/metrics.ts`, `hooks/band/register.tsx` |
| `claude/mods/status-band/hooks/register.tsx` | The band drawn at `ui.render` `AbovePrompt` with a button row, and the copy of the task as a Markdown table | `hooks/band/register.tsx`, `hooks/band/metrics.ts` |

Differences from the source: the code-file test keeps only the extensions
upstream reads definitions from; the band keeps no ledger, board, webhook,
token count or reuse share; callers open come from `removed-callers.py --json`
instead of a `git grep` per removed name; the Markdown table holds this band's
fields.

## License

```text
MIT License

Copyright (c) 2026 DietrichGebert

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
