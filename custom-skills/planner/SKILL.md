---
name: planner
description: >-
  Open a planner session: a temporary worker that investigates one scoped subject, grills the captain about it one question at a time, and publishes a spec or dependency-aware tickets only after the captain calls for it.
  Use when the captain invokes /planner, or asks to plan, scope, spec, or break down work before any implementation is authorized.
user-invocable: true
metadata:
  internal: true
---

# planner

A **planner session** is one temporary worker the captain talks to directly.
Firstmate opens it, points it at a subject, and then leaves the conversation.

It exists because the expensive planning mistakes are made before any code is written, and they are made by an agent that agreed too early.
A scout answers a question firstmate already knows how to ask.
A planner finds out what the question is, by arguing with the captain until the captain is satisfied that it understands - and it does not get to decide when that moment arrives.

The planner is not a second mate, not a one-shot scout, and not an implementation worker.
It produces a captain-approved artifact and nothing else.
**Planning never authorizes implementation.** Firstmate decides the delivery shape afterwards, as a separate captain-authorized lifecycle.

This skill owns the planner's launch lifecycle.
The planner session's contract lives at [`CONTRACT.md`](CONTRACT.md), reached by the brief in step 3.
`AGENTS.md` section 1 keeps the direct-conversation exception and section 7 keeps the intake trigger and the no-implementation boundary.

## What firstmate does

### 1. Take the three intake inputs

A planner session opens only when all three are explicit.
Ask one concise question for whichever is missing, and open nothing until it is answered:

1. **The project.** One registered project, resolved the ordinary way.
2. **The scope.** The code and documents the captain is putting in bounds, named concretely: modules, layers, directories, docs, specs, decision records.
3. **The planning question.** What the captain wants to come out of it, in their own words.

The scope is the captain's to set, not firstmate's to infer, because it is also the planner's hard boundary for the whole session.

**Completion criterion:** all three are written down, in the captain's terms, ready to paste into a brief.

### 2. Resolve the runtime

**Default: the pi runtime, model `cx/gpt-5.6-sol`, effort `high`.**

**The explicit alternative: the claude runtime, model `claude-opus-5`, effort `high`**, when the captain asks for Claude.

These two are the whole menu.
An explicit per-task captain choice replaces either; nothing else does, and a dispatch profile does not silently reroute a planner session.
`AGENTS.md` section 4 and `harness-adapters` turn the choice into concrete launch flags and spawn validation, carrying this pin through rather than substituting a best-fit alternative.

### 3. Scaffold the brief

Scaffold with `bin/fm-brief.sh <task-id> <project> --scout`.
A planner session is scout-shaped: no branch, no push, no PR, and a report that survives cleanup.

Fill `{SCOPE}` with the captain's scope from step 1, under the ordinary scope and seam contract that `bin/fm-brief.sh`'s header owns.

Fill `{TASK}` with the planning question, the captain's own words, and this instruction, with every path written in absolute form:

> Read and follow `<firstmate-home>/custom-skills/planner/CONTRACT.md`. It is your contract for this whole session.

Do not restate the contract in the brief.
The planner reads the contract from its own file, so the brief carries the pointer and none of the content.

**Completion criterion:** the brief names the contract by absolute path, carries the captain's scope verbatim, and has no `{TASK}` or `{SCOPE}` placeholder left.

### 4. Open the session and hand it to the captain

Spawn through `bin/fm-spawn.sh` with the resolved runtime, confirm the worker is processing its brief, and handle any trust dialog through `harness-adapters`.

Then tell the captain, in one message: the planner session is open, which project and scope it is working, and where to talk to it.
That message is firstmate's last word on the subject until the planner reports back.

### 5. Step out

Once the session is open, firstmate is not a participant.
Do not steer it, answer for the captain, summarize its discussion, or relay messages into it.

Monitoring is lifecycle only: whether the session is **alive, waiting, finished, or failed**.
Reading the live discussion to report progress is the thing this skill exists to prevent - it puts firstmate back in a conversation whose whole value is that the captain and the planner are speaking without a relay.

A planner session is quiet for long stretches by design, because it is waiting on the captain.
Its opening `paused:` line declares that wait, so a silent pane is its healthy state and gets the long recheck cadence rather than a stale-worker recovery.

Two things still reach firstmate normally: a `needs-decision:` or `blocked:` escalation, and the terminal report.

### 6. Take the return

On `done:`, read `data/<task-id>/report.md` and relay to the captain the published artifact's URLs or paths and the concise next actions.
Record the report as the completion artifact, then follow the ordinary scout outcome path: the shared completion gate under `decision-hold-lifecycle`, then cleanup.

The artifact recommends implementation; it does not authorize it.
When the captain separately authorizes the work, dispatch it as ordinary delivery, or route an accepted multi-ticket program to program orchestration.
