---
name: paired-review-driver
description: Driver procedure for an executable paired-review task.
disable-model-invocation: true
---

# Paired-review driver

Your brief carries `role=driver` and all runtime facts.
Read the task and owner-supplied context, create the named barrier acknowledgement, and wait for the release file before investigating.
Your isolated copy and branch are your only writable Git state.

## Live signals

Every live signal to the navigator uses the single verified pair-send method, `fm-pair-compose.sh send <recovery.json> navigator "<signal>"`, where `<recovery.json>` is the recovery evidence path from your brief's runtime facts.
The method resolves the navigator's task from the evidence and submits through `fm-send.sh`, so the signal counts as delivered only when submission is verified.
Never send a live signal directly to a Herdr agent or pane; Herdr is not a delivery API.

## Drive

1. Form a file-level plan without editing code.
   Record the plan and current HEAD in `pair-log.md`, then send `PLAN READY` with the verified pair-send method.
   Wait for the plan outcome before editing.
2. Answer each finding once with `accepted` or `rejected` and a reason.
   Answer only questions about your implementation choices.
   Route intent, scope, prior-decision, authority, and surviving-disagreement questions to the owner.
3. Declare meaningful milestones in durable history with current HEAD, then send `MILESTONE <id>` with the verified pair-send method.
   Continue accepted-scope work while the navigator checks unless a stop arrives.
4. On `STOP <id>`, finish the command already running, send `ACK STOP <id>` with the verified pair-send method, and hold edits, validation, push, and PR work.
   After acknowledgement, record your one bounded response beneath the navigator's durable finding.
   Missing evidence or a dispute after that response goes to the owner.
5. Before delivery, declare the final gate and wait for the navigator outcome.
   The final gate cannot be bypassed.

Live signals (`PLAN READY`, `MILESTONE`, `STOP`, `ACK STOP`, and direct pointers) always use the verified pair-send method.
`pair-log.md` preserves material reasoning; it is not a queue or receipt.
Do not poll it as normal coordination.
Current code truth comes from Git in your copy.

If navigator coverage disappears, report it immediately.
You may continue only accepted-scope implementation under an approved plan.
Hold at the initial plan gate, authority decisions, active stops, and final review until coverage is restored and verified.
