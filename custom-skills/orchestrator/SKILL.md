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
It holds the one thing none of its workers can hold: the view across every ticket at once.

Its home is **leased** - its own firstmate copy, held for the programme's term.
A lease is the whole design: the home outlives a dead agent, carries that session's record of its own workers, and is returned when the programme ends.
It is not a second mate: no registry line, no charter, no inherited material, no liveness sweep.
`bin/fm-supervisor-lib.sh` owns that lifecycle, and `bin/fm-spawn.sh --help` owns its flags.

## The boundary

**Firstmate does intake and opens the session.
The supervisor owns the programme.**

Steps 1 to 5 are firstmate's whole part: take the intake inputs, confirm every named project is already cloned here, resolve the supervisor's own runtime profile, write the packet and the brief, launch the session, and confirm it is processing that brief.
From there firstmate holds lifecycle only - alive, waiting, finished, or failed - plus the escalations in step 5 and the return in step 7.

The supervisor owns the programme from launch on:

- Its procedure is [`PROGRAMME.md`](PROGRAMME.md), which the step 4 brief points it at, and which reaches [`ROUTING.md`](ROUTING.md) and [`program-orchestration`](../program-orchestration/SKILL.md) on their own triggers.
- It decomposes the authorized work into task cards and maps their dependencies and custody.
- It resolves each child worker's concrete harness, model, and effort through the ordinary per-task routing, and records that routing on the child's card.
- It spawns, supervises, and reconciles its own children, and owns the programme's evidence and delivery.

That procedure stays out of this file: firstmate opens the session and never runs it.

## 1. Take the intake inputs

Ask one concise question for whichever is missing, and open nothing until it is answered:

1. **The programme id** - one short slug, used for the session, the brief, and the decision directory.
2. **The work** - the spec path, ticket set, or issue query, plus the captain's sentence that authorized implementing it.
3. **The projects** it lands in.

A spec, report, or recommendation is evidence that work is worth doing; the captain's word is what makes it startable.

The supervisor allocates every worker copy from this home's existing clones and clones nothing itself, so a named project missing from `projects/` is a gap to close before opening, not after.

The supervisor adds the interpreted revision and the non-goals on top of these three; [`PROGRAMME.md`](PROGRAMME.md) step 1 owns that half, so do not collect it here.

**Done when:** all three are written in the captain's terms, the authorization is a captain sentence you can quote, and every named project is present under `projects/`.

## 2. Resolve the supervisor's runtime

This step resolves exactly one profile: the supervisor's own.

**Default: the claude runtime, model `claude-opus-5`, effort `xhigh`.**

An explicit per-task captain choice replaces it; a dispatch profile leaves it alone.
`data/captain-shared.md` still binds, so a model named by a programme record is a fallback order, not a pin.

The pin is the supervisor's alone and never propagates to a child.
The supervisor alone resolves each child worker's harness, model, and effort, at the moment it dispatches that child.
A child's route turns on programme state that does not exist yet at intake: what has landed, what is in flight, and what that ticket turned out to need.
Every supervisor or worker spawn passes concrete `--harness`, `--model`, and `--effort` values.
No programme spawn may inherit a Pi default model.
`cx/gpt-5.6-sol` is invalid for supervisors and implementation workers; only a separately launched planner may select it.

**Done when:** the supervisor's runtime, model, and effort are three concrete values ready for spawn validation, the only profile resolved at intake is the supervisor's, and every launch records all three explicit flags.

## 3. Write the initialization packet

A leased home starts with no `data/learnings.md` - only `captain-shared.md` propagates - so the packet is where this session learns what the tooling does wrong today.

Write it under the programme's decision directory: each current defect of the spawn, base, cleanup, and supervision tooling, with its workaround.

The packet is **tool state at open time**, not doctrine.
A fixed tool shortens the packet and leaves this skill untouched.

**Done when:** the file exists, every defect in it names a workaround, and it is written before step 5 spawns anything.

## 4. Scaffold the brief

Scaffold with [`fm-supervisor-brief.sh`](fm-supervisor-brief.sh) `<programme-id>`.
It writes the home, worker-allocation, status, records, and definition-of-done contract, and its closing line names the two placeholders it leaves for you.

Its **Task** section takes the work from step 1 and these three, every path absolute:

> Read and follow `<firstmate-home>/custom-skills/orchestrator/PROGRAMME.md`. It is your procedure for this whole programme.
> Your decision records go in `<firstmate-home>/data/<programme-id>/`, one file per decision.
> Your initialization packet is at `<absolute path>`.

Its **Scope and seams** section takes the boundary the programme returns to the captain to widen.

Both sections state the body of work and its edges; the task cards inside it, and the worker each card gets, are the supervisor's to choose.

**Done when:** the brief carries neither placeholder the scaffold left, all four paths above are absolute, and the brief hands the authorized work over whole, without task cards and without a child worker's profile.

## 5. Open it, hand it over, step out

```
bin/fm-spawn.sh <programme-id> --supervisor --harness <runtime> --model <model> --effort <effort>
```

Before any child dispatch, resolve and record the same three explicit values on that ticket's routing card, then pass all of them to `fm-spawn.sh`.

That one command takes the lease, marks the home, records it, and launches the session in it.
It takes no project argument: the home is a firstmate copy, and the product projects stay where they are.
`data/secondmates.md` is byte-identical afterwards - a step that asks you to register this session is a step that has confused it for a second mate.

Every launch in this programme names its profile out loud with `--harness`, `--model`, and `--effort`: this one from step 2, and every worker launch from the routing the supervisor resolves for that child.
A launch that names all three is a launch that inherited nothing by silence.

Then tell the captain in one message where to talk to it.

That message is firstmate's last word on the subject until the session reports back.
Monitoring from here is lifecycle only: **alive, waiting, finished, or failed.**
The task cards, the child routing, and the workers all belong to the session, and its child tree is reconciled, recovered, and cleaned up from inside its own home.

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
