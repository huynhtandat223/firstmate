---
name: swarm
description: Load when the captain says swarm, or before a verify round across two or more pages, a cross-repository audit, or a race on a bug that failed two rounds; read the usage meters first and record them in the backlog note.
metadata:
  internal: true
---

# Swarm

Firstmate runs the swarm, because only firstmate starts other sessions.
It fans out several workers, drains them, and returns one consolidated report.

The backlog item and its note are the swarm's todolist.
Before launching anything, write one entry per phase in that note (Frame, Fan out, Aggregate, Report), and mark each entry as its phase completes.

## Phase A: Frame

1. State the done predicate and the report the swarm returns.
2. Choose the shape: partition into slices, race several workers on identical briefs, or mix both.
   For a race or mixed shape, declare `first pass`, `rank all` or `best-of` in the backlog note before spawning.
3. Read the usage meters before fan-out and record each reading in the backlog note: the Claude status line (5 h and week) of every Claude account a worker may use, and the 9router quota (the "Model quota truth" paragraph in `data/5001-ops/README.md`).
4. Pick each worker's harness, model and effort from `data/captain.md` "Workers and models", never Fable or `cx/gpt-6-astra`.
   For a model race, name each arm's model up front.
5. A slice is a worker started by `bin/fm-spawn.sh` in its own worktree, with `--scout` when it writes no PR.
   It is briefed through `bin/fm-brief.sh` and reports in `data/<id>/report.md` plus a `done:` line.
6. When workers verify or measure commits, each brief names the exact SHAs and the method (sample count, what one sample is, order).
   The worker records both in its result.
7. A slice that touches company, 5001 or a Titan takes its environment lease first, with `bin/fm-lease.sh claim env:<name> --holder <id>` (contract in `bin/fm-lease-lib.sh`), and releases it when it finishes.
8. A UI slice serves its own Storybook from its own worktree on its own port and measures with `verify-cfw --target url:<base>`, where `<base>` is that Storybook.
   Port 5010 is the captain's UI/UX review Storybook; a slice never serves on it or measures against it.

## Phase B: Fan out

Every brief stands alone: the goal, the scope, the exact slice or race arm, how to verify, and what to report.
Reports use `PASS`, `ISSUES` or `BLOCKED` with evidence.
A worker that can prove a defect reports `ISSUES` and lists every issue it can prove, not only the first.

Start every worker in the same turn, one `bin/fm-spawn.sh` per worker, and supervise each like any other worker.
Redirect a running worker with `bin/fm-send.sh`.

## Phase C: Aggregate

Read each terminal result in `data/<id>/report.md`.
Drop a result that does not record the SHAs and method its brief names, and relaunch that worker once with `bin/fm-control.sh <id> relaunch`.
A worker that stops without a result gets the same single relaunch.
After a second miss, record a gap; a gap is not a pass.
For coverage, every required slice needs a result.
For a race, apply the selection rule declared in Phase A.

When every result is in or recorded as a gap, stop each slice's Storybook and tear down every worker with `bin/fm-teardown.sh`.

## Phase D: Report

Write one consolidated report, never a paste of raw worker output:

- a result table with one row per slice or arm: its SHAs, its method, and `PASS`, `ISSUES`, `BLOCKED` or gap;
- one line per issue, with its evidence;
- the gaps and dropouts, each with its reason;
- the race rule, when one was used.

The report goes to the backlog note, and to the captain when the captain asked for the swarm.
