---
name: handoff-session
description: >-
  Handoff procedure: move a live worker's task onto a fresh session on the same harness and model.
  Use on handoff-needed or handoff-limit notifications, when a peek shows a worker's context meter at the home's handoff threshold with work left, or when the captain asks for a handoff.
user-invocable: false
metadata:
  internal: true
---

# handoff-session

A handoff gives the same worker a fresh context: the replacement runs on the exact harness, model and effort recorded for the task.
The home's thresholds and any model-specific exemptions live in `data/captain.md`; this skill owns the procedure.

## Automatic context notifications

On `handoff-needed`, use the procedure below when work remains.
Claude and Pi workers emit this once per session at the configured context threshold; `bin/fm-context-handoff.mjs` owns measurement and counting.
On `blocked [key=handoff-limit]`, stop the worker at a safe point, inspect the work and its evidence, and judge quality before deciding the next action.
Keep that worker stopped without relaunching; resolve the keyed blocker through `fm-send --resolve-key handoff-limit` only when the decision is made.

## 1. Ask the worker for the handoff

Steer the worker through `bin/fm-send.sh` with one message that asks it to:

- stop at the next safe point;
- preserve everything that builds on every branch the task owns per the task's delivery mode, and name anything left uncommitted (local-only and no-mistakes workers never push from their copy);
- write the handoff with Matt's handoff skill (`custom-skills/matt/productivity/handoff/SKILL.md` in the firstmate home), saved to `data/<task-id>/handoff.md` in the firstmate home (this path replaces that skill's temporary-directory default);
- attach that file with `bin/fm-task.sh handoff <task-id> --document <file> --document-title Handoff`, retaining the file as an offline cache;
- cover the captain's current asks in his own words, every branch with its preserved head and location, every PR, live host and lab state, evidence so far, what is left, and open questions;
- append a `handoff written` status line and end its turn.

Done when the status line exists, `data/<task-id>/handoff.md` exists, and every branch the handoff names has its recorded head preserved per the task's delivery mode.

## 2. Relaunch on the same adapter

Run `bin/fm-control.sh <task-id> relaunch --note "<note>"` with no `--harness`, `--model` or `--effort`, so a ship or scout keeps the adapter already recorded in `state/<task-id>.meta`.
The note tells the replacement to run `bin/fm-task.sh document <task-id> --kind handoff` first (if 5001 is unavailable, read `data/<task-id>/handoff.md` and report its cache age), names the preserved heads and their locations, lists what is left, and says to keep working until the next deliverable or a real blocker.

Done when `fm-control` reports the relaunch and the recorded harness, model and effort equal those recorded before the handoff.

## 3. Restore monitoring

If the task has a PR, run `bin/fm-pr-check.sh <task-id> <PR url>` again, because the watcher rejects the pre-relaunch poll.
Peek the new pane.

Done when the replacement shows it has read the handoff and is working from the recorded head.
