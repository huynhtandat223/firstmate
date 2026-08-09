---
name: orchestrator
description: >-
  Open or relaunch a programme supervisor: one temporary firstmate session the captain talks to directly, which drives an authorized spec, ticket set, or issue set to completion through its own implementation workers.
  Use when the captain invokes /orchestrator, asks to run a programme whose implementation is already authorized, or a live programme supervisor has stopped.
user-invocable: true
metadata:
  internal: true
---

# orchestrator

A **programme supervisor** is one temporary firstmate session the captain talks to directly.
Firstmate opens it, hands it a body of authorized work, and leaves the conversation.

Its input is a spec, a ticket set, or GitHub issues; the backlog stays firstmate's own queue.
It dispatches and supervises its own workers, and holds the one thing none of them can hold: the view across every ticket at once.

Its home is **leased** - its own firstmate copy, held for the programme's term.
A lease is the whole design: the home outlives a dead agent, carries that session's record of its own workers, and is returned when the programme ends.
It is not a second mate: no registry line, no charter, no inherited material, no liveness sweep.
`bin/fm-supervisor-lib.sh` owns that lifecycle, and `bin/fm-spawn.sh --help` owns its flags.

The session's own contract is [`CONTRACT.md`](CONTRACT.md), reached by the brief in step 4.
Firstmate opens the session and never runs it, so that file stays out of this one.

## 1. Take the intake inputs

Ask one concise question for whichever is missing, and open nothing until it is answered:

1. **The programme id** - one short slug, used for the session, the brief, and the decision directory.
2. **The work** - the spec path, ticket set, or issue query, plus the captain's sentence that authorized implementing it.
3. **The projects** it lands in.

A spec, report, or recommendation is evidence that work is worth doing; the captain's word is what makes it startable.

The supervisor allocates every worker copy from this home's existing clones and clones nothing itself, so a named project missing from `projects/` is a gap to close before opening, not after.

**Done when:** all three are written in the captain's terms, the authorization is a captain sentence you can quote, and every named project is present under `projects/`.

## 2. Resolve the runtime

**Default: the claude runtime, model `claude-opus-5`, effort `xhigh`.**

An explicit per-task captain choice replaces it; a dispatch profile leaves it alone.
`data/captain-shared.md` still binds, so a model named by a programme record is a fallback order, not a pin.

The pin is the supervisor's alone.
Each worker it dispatches resolves its own profile through the ordinary per-task routing.

**Done when:** the runtime, model, and effort are three concrete values ready for spawn validation.

## 3. Write the initialization packet

A leased home starts with no `data/learnings.md` - only `captain-shared.md` propagates - so the packet is where this session learns what the tooling does wrong today.

Write it under the programme's decision directory: each current defect of the spawn, base, cleanup, and supervision tooling, with its workaround.

The packet is **tool state at open time**, not doctrine.
A fixed tool shortens the packet and leaves this skill untouched.

**Done when:** the file exists, every defect in it names a workaround, and it is written before step 5 spawns anything.

## 4. Scaffold the brief

Scaffold with [`fm-supervisor-brief.sh`](fm-supervisor-brief.sh) `<programme-id>`.
It writes the home, worker-allocation, status, records, and definition-of-done contract, so this step fills only the two placeholders.

Fill `{TASK}` with the work from step 1 and these three, every path absolute:

> Read and follow `<firstmate-home>/custom-skills/orchestrator/CONTRACT.md` and `<firstmate-home>/custom-skills/program-orchestration/SKILL.md`. They are your contract for this whole programme.
> Your decision records go in `<firstmate-home>/data/<programme-id>/`, one file per decision.
> Your initialization packet is at `<absolute path>`.

Fill `{SCOPE}` with the boundary the programme returns to the captain to widen.

**Done when:** no `{TASK}` or `{SCOPE}` placeholder remains, and all four paths above are absolute.

## 5. Open it, hand it over, step out

```
bin/fm-spawn.sh <programme-id> --supervisor --harness <runtime> --model <model> --effort <effort>
```

That one command takes the lease, marks the home, records it, and launches the session in it.
It takes no project argument: the home is a firstmate copy, and the product projects stay where they are.
`data/secondmates.md` is byte-identical afterwards - a step that asks you to register this session is a step that has confused it for a second mate.

Then tell the captain in one message where to talk to it.

That message is firstmate's last word on the subject until the session reports back.
Monitoring from here is lifecycle only: **alive, waiting, finished, or failed.**
The session's workers belong to the session, and its child tree is reconciled, recovered, and cleaned up from inside its own home.

A `needs-decision:` or `blocked:` escalation and the terminal report reach firstmate normally.

**Done when:** the session is processing its brief, `data/secondmates.md` is unchanged, and the captain has one message naming where to talk to it.

## 6. Relaunch a stopped supervisor

A stopped supervisor is not a lost programme: the lease held its home, and the home holds its whole worker inventory.

**One programme, one supervisor, one home.**
Re-run the exact step 5 command with the same programme id.
It returns into that same home and reconciles the workers already recorded there, which is what keeps a ticket from getting a second worker.

A spawn that refuses because the recorded home is gone is a captain-facing finding: that home was the only record of the programme's workers.

**Done when:** the same session id is live in the same home, or the captain has the finding.

## 7. Take the return

On `done:`, read `data/<programme-id>/report.md`, relay the outcome and next actions to the captain, then follow the ordinary scout outcome path: the shared completion gate under `decision-hold-lifecycle`, then cleanup.

Cleanup names anything still outstanding - a worker record left in the home, unlanded work, an unresolved decision, a missing report - and refuses until it is reconciled.
Resolve what it names; a forced cleanup discards the programme's own record of its workers.
Returning the home releases the lease.

The decision records under `data/<programme-id>/` outlive the session; keep them.

**Done when:** the captain has the outcome and next actions, the completion gate has passed, cleanup succeeded, and the decision records survive it.
