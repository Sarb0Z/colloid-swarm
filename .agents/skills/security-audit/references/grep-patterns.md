# Grep Patterns for Security Audit

Starting greps for a JavaScript/TypeScript stack. Adapt the file globs to the
detected language before running these — `--include="*.js"` finds nothing in
a Python, Ruby, or Go codebase. Swap the glob (`*.py`, `*.rb`, `*.go`, `*.java`)
and the framework-specific pattern (route macros, middleware names) to match
what Phase 0 identified.

## Dependency vulnerabilities

```bash
npm audit --audit-level=moderate
pip-audit
bundler-audit
```

## Secret scanning

```bash
grep -rn "password\s*=" --include="*.js" --include="*.ts" --include="*.py" src/
grep -rn "sk-\|api_key\|secret\|token" --include="*.env*" .
```

## Hardcoded values

```bash
grep -rn "localhost\|127.0.0.1\|hardcoded" --include="*.js" src/
```

## Find all routes (Express example)

```bash
grep -rn "router\.\(get\|post\|put\|delete\|patch\)" --include="*.js" src/
```

## Find auth middleware usage

```bash
grep -rn "authenticate\|authorize\|requireAuth\|@login_required\|middleware" --include="*.js" src/
```

## Find raw SQL

```bash
grep -rn "query(\`\|\.query(\"" --include="*.js" src/
```
