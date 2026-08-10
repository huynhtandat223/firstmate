---
name: paired-review-driver
description: Driver procedure for an executable paired-review task.
disable-model-invocation: true
---

# Paired-review driver

Your brief carries `role=driver` and all runtime facts.
Read the task and owner-supplied context, create the named barrier acknowledgement, and wait for the release file before investigating; if that wait runs out, go solo.
Your isolated copy and branch are your only writable Git state.

## Live signals

Every live signal to the navigator uses the single verified pair-send method, `fm-pair-compose.sh send <recovery.json> navigator "<signal>"`, where `<recovery.json>` is the recovery evidence path from your brief's runtime facts.
The method resolves the navigator's task from the evidence and submits through `fm-send.sh`, so the signal counts as delivered only when submission is verified.
An unconfirmed signal says nothing about the navigator: submission to a worker that is already mid-turn is unconfirmable on several harnesses, and both roles are mid-turn whenever they are waiting on each other.
Send once, record it, and read coverage from the navigator's output instead.
Never send a live signal directly to a Herdr agent or pane; Herdr is not a delivery API.

## Drive

1. Form a file-level plan without editing code.
   Record the plan and current HEAD in `pair-log.md`, then send `PLAN READY` with the verified pair-send method.
   Wait for the plan outcome before editing, bounded as under Solo.
2. Answer each finding once with `accepted` or `rejected` and a reason.
   Answer only questions about your implementation choices.
   Route intent, scope, prior-decision, authority, and surviving-disagreement questions to the owner.
3. Declare meaningful milestones in durable history with current HEAD, then send `MILESTONE <id>` with the verified pair-send method.
   Continue accepted-scope work while the navigator checks unless a stop arrives.
4. On `STOP <id>`, finish the command already running, send `ACK STOP <id>` with the verified pair-send method, and hold edits, validation, push, and PR work until the navigator answers or the Solo bound passes.
   After acknowledgement, record your one bounded response beneath the navigator's durable finding.
   Missing evidence or a dispute after that response goes to the owner.
5. Before delivery, declare the final gate and wait for the navigator outcome, bounded as under Solo.
   The final gate is always declared and always recorded, by the navigator when it answers and by you when it does not.

Live signals (`PLAN READY`, `MILESTONE`, `STOP`, `ACK STOP`, and direct pointers) always use the verified pair-send method.
`pair-log.md` preserves material reasoning; it is not a queue or receipt.
Do not poll it as normal coordination.
Current code truth comes from Git in your copy.

## Solo

Paired review lowers the risk of building the wrong thing; it is not a precondition for building it.
Coverage is the navigator's own durable output, its `pair-log.md` entries and findings, never the result of your send.
Read that history once when a bound expires, which is a gate decision rather than the routine polling ruled out above.

Go **solo** when a bounded wait produces no navigator output: five minutes, at the release barrier and at any gate you declared.
Solo means announce once, in `pair-log.md` and one status line, that pair review fell and you are continuing, then keep implementing to the same standard and through the same gates, writing each gate outcome as your own.
Carry that announcement into the PR body, so the owner reviews what the navigator would have.

Escalate to the owner rather than deciding solo: any finding already open, and any authority, scope, destructive, irreversible, or security-sensitive decision.
A navigator that resumes rejoins at the next gate; record that it did.
