---
name: paired-review-navigator
description: Navigator procedure for an executable paired-review task.
disable-model-invocation: true
---

# Paired-review navigator

Your brief carries `role=navigator`, the driver's read-only copy path, and all runtime facts.
Create the named barrier acknowledgement and wait for the release file before investigating.
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
   Apply the Spec axis of `code-review/SKILL.md`; review architecture/direction; and form the initial changed-actor trigger/proof map using `classical-testing/SKILL.md`.
   Record the plan outcome, current driver HEAD, last completed gate, and open finding ids.
   The driver waits for this outcome before editing, but only for a bounded wait, after which it proceeds solo; deliver the outcome regardless and reconcile against its current HEAD.
3. On each milestone, inspect the driver's Git status, diff summary, diff, branch, HEAD, changed source, and task checks directly.
   Apply the Standards axis; scope/coupling checks; proof sensitivity; and strongest-authorized-real-path checks.
   Use the same evidence at the final gate.
   When the driver's work touches an agent-facing document (a skill, `AGENTS.md`, `CLAUDE.md`, or docs/guidance an agent consumes), the navigator itself loads and applies `writing-for-agents/SKILL.md`; it does not merely remind the driver.
   `pair-log.md` never substitutes for current Git truth.
4. For a credible wrong direction or scope breach, send `STOP <finding-id>` first, with the verified pair-send method.
   Require `ACK STOP <finding-id>` as semantic delivery confirmation, then record the finding and evidence.
   Report a missing acknowledgement to the owner.
5. For non-urgent material findings or questions, record the unique `N<n>` or `Q<n>` entry first, then send a short direct pointer with the verified pair-send method.
   Accept one response only; surviving disagreement goes to the owner.
6. At every gate answer: Apply complete Standards and Spec review; writing-for-agents on every changed agent-facing document; and classical-testing across every changed actor trigger, all against the exact driver/PR head.
   Record a self-contained verdict naming exact head, findings, proof map, and whether each capability completed.
7. Record the final outcome and current driver HEAD before completion.

Between direct signals, remain idle.
You do not run `sleep`, periodically read pair logs, status, or panes, or create your own polling cadence.
The driver writes each plan or milestone to the durable pair log and sends the single verified notification once.
You review immediately when that direct milestone or event arrives and write findings or acknowledgement through the existing paired-review channels.
Preserve immediate STOP authority whenever you have concrete evidence already available.
Recovery for a failed or missing direct notification is owner-driven or event-driven, not timer-based.
Escalate scope or accepted-contract change, destructive, irreversible, or security-sensitive action, and surviving disagreement.
Pair agreement never expands authority.

After navigator or topology recovery, reconcile the current driver Git evidence, topology generation, durable gate history, and open finding ids before issuing an outcome.
