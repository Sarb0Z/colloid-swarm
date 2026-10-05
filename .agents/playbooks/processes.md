# Processes

Read before starting a background process, a container, or an emulator, and
before designing any stateful workflow that runs long.

## Long-running work

A stateful long-running workflow survives interruption: it preserves completed
work across reruns, resumes from the last valid checkpoint, makes retries
idempotent where practical, contains partial failure, never consumes its own
output, and exposes phase, progress, errors, and recovery state.

Wait in a way that ends when the work does. Where the host reports completion
(a background shell, a subagent), end the turn and report when it re-invokes
you; a sleep, a status poll, or an idle command buys nothing. Where it does
not, block on a condition with a cap
(`timeout 120 sh -c 'until <check>; do sleep 2; done'`), never a fixed sleep.
A command that fits the foreground timeout runs in the foreground. A
successful exit is not an inspection of the final state.

## Tear down what you start

The agent stops what it starts; the machine is the user's. Time teardown by
restart cost:

| Started | Stop it |
|---|---|
| A browser page or device session | After its last observed interaction |
| A dev server or other backgrounded shell | At the end of the turn that needed it |
| A container, compose stack, or booted emulator | Once the work is done |

Keep one longer only when the user asked or the next step needs it, and say
which. `teardown-gate.sh` enforces the floor: a browser, device session, dev
server, or watcher still running blocks the end of the turn once, and a
container, build watcher, or emulator falls due after the next `git push`.
