---
name: paired-review-driver
description: Driver procedure for an executable paired-review task.
disable-model-invocation: true
---

# Paired-review driver

Your brief carries `role=driver` and all runtime facts.
Read the task and owner-supplied context, create the named barrier acknowledgement, and wait for the release file before investigating.
Your isolated copy and branch are your only writable Git state.

## Drive

1. Form a file-level plan without editing code.
   Record the plan and current HEAD in `pair-log.md`, then send `PLAN READY` to the navigator's Herdr agent target.
   Wait for the plan outcome before editing.
2. Answer each finding once with `accepted` or `rejected` and a reason.
   Answer only questions about your implementation choices.
   Route intent, scope, prior-decision, authority, and surviving-disagreement questions to the owner.
3. Declare meaningful milestones in durable history with current HEAD, then send `MILESTONE <id>`.
   Continue accepted-scope work while the navigator checks unless a stop arrives.
4. On `STOP <id>`, finish the command already running, send `ACK STOP <id>`, and hold edits, validation, push, and PR work.
   After acknowledgement, record your one bounded response beneath the navigator's durable finding.
   Missing evidence or a dispute after that response goes to the owner.
5. Before delivery, declare the final gate and wait for the navigator outcome.
   The final gate cannot be bypassed.

Herdr messages coordinate live work.
`pair-log.md` preserves material reasoning; it is not a queue or receipt.
Do not poll it as normal coordination.
Current code truth comes from Git in your copy.

If navigator coverage disappears, report it immediately.
You may continue only accepted-scope implementation under an approved plan.
Hold at the initial plan gate, authority decisions, active stops, and final review until coverage is restored and verified.
