import { expect, test } from 'claude-code/testing'

import { isTestRun } from '../hooks/task'

// Whether a Bash command's exit status is a test runner's, so the band may
// read pass or fail from it.

test('a runner in command position counts, through a launcher or after &&', async () => {
  for (const command of [
    'pytest -q',
    'pytest 2>&1',
    'FORCE_COLOR=0 pytest tests/',
    'uv run pytest tests/ -q',
    'python -m pytest',
    'python3 -m pytest -x',
    'npx vitest run',
    'pnpm exec jest',
    'npm test',
    'npm run test',
    'go test ./...',
    'cd app && pytest',
    'pytest && echo ok',
    'time pytest',
    'time -p pytest',
    'env CI=1 FOO=bar pytest',
    'timeout 600 pytest',
    'timeout -s KILL 10m pytest',
    'nice pytest',
    'nice -n 10 pytest',
    'command pytest',
    '(cd app && pytest)',
    'pytest;',
    'pytest\n',
    'pytest -q  # all of it',
    'FOO="a b" pytest',
    "FOO='a b' pytest",
    'uv run --with x pytest',
    'uv run --frozen --python 3.14 pytest -q',
    'npm run test:unit',
    'pnpm test -- --watch=false',
    'npm run test.unit',
    'yarn test-ci',
    'cd app && \\\n  pytest -q',
    'uv run \\\npytest',
  ]) {
    expect(isTestRun(command), command).toBe(true)
  }
})

test('this repository\'s own runners count', async () => {
  for (const command of [
    '.agents/suite.sh',
    '/Users/me/repo/.agents/suite.sh',
    '.agents/check-all.sh',
    'bash .agents/test-owed.sh',
    '.agents/test-statusline.sh',
    'python3 .agents/test-lsp.py',
    'claude plugin test .agents/claude/mods/status-band',
    'command claude plugin test .agents/claude/mods/status-band',
  ]) {
    expect(isTestRun(command), command).toBe(true)
  }
})

test('a runner whose exit status does not reach the end does not count', async () => {
  for (const command of [
    'pytest -q 2>&1 | tail -20',
    'pytest | tee log',
    'pytest &',
    'pytest; echo done',
    'pytest || true',
    'pytest\necho done',
  ]) {
    expect(isTestRun(command), command).toBe(false)
  }
})

test('a runner word anywhere but command position does not count', async () => {
  for (const command of [
    'uv pip install pytest',
    'rg jest',
    'echo "pytest"',
    'git commit -m "run pytest | tail"',
    'cat .agents/test-owed.sh',
    'command -v pytest',
    'npm run testdata:seed',
    'yarn testing',
    'ls',
  ]) {
    expect(isTestRun(command), command).toBe(false)
  }
})

test('a comment ends at its newline, so the command after it decides', async () => {
  expect(isTestRun("pytest -q  # confirm it's green\ngit status")).toBe(false)
  expect(isTestRun('git status  # then pytest')).toBe(false)
  expect(isTestRun('# pytest\nls')).toBe(false)
  expect(isTestRun("cd app  # don't skip\npytest")).toBe(true)
})

test('a quote still open at the end is no test run', async () => {
  expect(isTestRun("pytest -q -k 'login")).toBe(false)
  expect(isTestRun('pytest -m "slow')).toBe(false)
})
