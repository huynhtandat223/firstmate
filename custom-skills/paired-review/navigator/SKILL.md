---
name: paired-review-navigator
description: Navigator procedure for an executable paired-review task.
disable-model-invocation: true
---

# Paired-review navigator

Your brief carries `role=navigator`, the driver's read-only copy path, and all runtime facts.
Create the named barrier acknowledgement and wait for the release file before investigating; after five minutes without it, begin your independent reading anyway and say so in `pair-log.md`.
Your own copy preserves independent analysis.
You may read the driver's copy but never write, edit, commit, push, or merge there.

## Live signals

Every live signal to the driver uses the single verified pair-send method, `fm-pair-compose.sh send <recovery.json> driver "<signal>"`, where `<recovery.json>` is the recovery evidence path from your brief's runtime facts.
The method resolves the driver's task from the evidence and submits through `fm-send.sh`, so the signal counts as delivered only when submission is verified.
An unconfirmed signal says nothing about the driver: submission to a worker that is already mid-turn is unconfirmable on several harnesses.
Send once, record the finding in durable history where it survives regardless, and escalate rather than resend.
Never send a live signal directly to a Herdr agent or pane; Herdr is not a delivery API.

## Navigate

1. Independently read the task, owner context, and relevant code before reading the driver's plan or history entry.
   Record your conclusion in `pair-log.md`.
2. On `PLAN READY`, inspect the driver's branch and HEAD, then compare its plan with your independent conclusion.
   Record the plan outcome, current driver HEAD, last completed gate, and open finding ids.
   The driver waits for this outcome before editing, but only for a bounded wait, after which it proceeds solo; deliver the outcome regardless and reconcile against its current HEAD.
3. On each milestone, inspect the driver's Git status, diff summary, diff, branch, HEAD, changed source, and task checks directly.
   Use the same evidence at the final gate.
   At the plan gate and each milestone, when the driver's work touches an agent-facing document (a skill, `AGENTS.md`, `CLAUDE.md`, or docs/guidance an agent consumes), remind the driver once to load and apply `custom-skills/matt/productivity/writing-for-agents/SKILL.md`; that skill owns the writing process, so point to it, never restate it.
   `pair-log.md` never substitutes for current Git truth.
4. For a credible wrong direction or scope breach, send `STOP <finding-id>` first, with the verified pair-send method.
   Require `ACK STOP <finding-id>` as semantic delivery confirmation, then record the finding and evidence.
   Report a missing acknowledgement to the owner.
5. For non-urgent material findings or questions, record the unique `N<n>` or `Q<n>` entry first, then send a short direct pointer with the verified pair-send method.
   Accept one response only; surviving disagreement goes to the owner.
6. At every gate answer: Was the stated reason delivered? Where did the coupling go? Does this repeat a harmful repository shape? What did the task leave for implementation to decide?
7. Record the final outcome and current driver HEAD before completion.

Stay active at gates and between direct signals.
A signal you never received is indistinguishable from a driver that has not reached a gate, so when you are idle, read the driver's durable gate entries and current HEAD to find the work rather than waiting to be told.
Routine pings and acknowledgements do not enter durable history.
Escalate scope or accepted-contract change, destructive, irreversible, or security-sensitive action, and surviving disagreement.
Pair agreement never expands authority.

After navigator or topology recovery, reconcile the current driver Git evidence, topology generation, durable gate history, and open finding ids before issuing an outcome.
