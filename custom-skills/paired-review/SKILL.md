---
name: paired-review
description: >-
  Agent-only owner protocol for composing high-blast-radius implementation work as an executable Herdr driver/navigator pair.
  Use before dispatching a database migration, contract or schema change, subsystem deletion or relocation, or captain-named paired task, and while restoring or deciding an escalation from such a pair.
user-invocable: false
metadata:
  internal: true
---

# Paired review owner

This parent skill owns pair intake, composition, recovery, and authority.
Workers do not read it.
The driver reads [`driver/SKILL.md`](driver/SKILL.md), and the navigator reads [`navigator/SKILL.md`](navigator/SKILL.md).

Pair only implementation work with high blast radius: a database migration, contract or schema change, subsystem deletion or relocation, or a task the captain names as paired.
Diagnosis remains one-worker root-cause work.
Ordinary work keeps the generic dispatch path.

## Compose

1. Preserve the existing task and scope statement verbatim as authoritative input.
   For a standalone task, add no rules, documentation, architecture guidance, or acceptance criteria unless the captain supplied them.
   For an epic task, pass the current task plus authoritative parent specs or issues as context; the current task remains implementation scope and sibling tasks remain outside it.
2. Resolve independent driver and navigator dispatch profiles under the ordinary Firstmate rules.
3. Invoke [`fm-pair-compose.sh`](fm-pair-compose.sh) once.
   Its `--help` owns exact flags.
   It uses ordinary `fm-spawn.sh` launches, then verifies and publishes one Herdr pair and releases each role's `PAIR READY` through the verified pair-send method before either role starts.
4. Treat the helper's `data/<pair-id>/recovery.json` as the composition and recovery record.
   A ready result proves distinct task identities, copies, branches, and Git directories; one session, workspace, and tab; named role agents; reciprocal adjacency; barrier acknowledgement; and exact role instructions.
   Existing task records remain authoritative for worker lifecycle.
5. Supervise both roles as one backlog item.
   The helper preserves partial launches and names the failed invariant rather than presenting one worker as a pair.

The role instructions contain facts rather than copied protocol: pair and peer identities, agent targets, shared history, copy and branch identities, current task, owner-supplied context, and task checks.

## Coordination and evidence

The single live-signal API for both roles is `fm-pair-compose.sh send <recovery.json> <driver|navigator> "<signal>"`.
It resolves the recipient task from the recovery evidence and submits through `fm-send.sh`, so every signal is Enter-verified before it counts as delivered.
Herdr arranges pair topology only; it is never a text-delivery API, and role instructions never name Herdr targets as send destinations.
`pair-log.md` is durable reasoning and gate history, not a queue, liveness signal, delivery receipt, or current-code store.
Current code truth is the driver's Git status, diff, branch, HEAD, and source.

Durable history records pair identity and topology generations, independent conclusion, plan, milestones, gate outcomes, unique findings and questions, one bounded response, owner decisions, last completed gate, open findings, and driver HEAD at each gate.
Routine pings stay out of it.

Short signals all use the verified pair-send method: `PAIR READY`, `PLAN READY`, `MILESTONE M2`, `CHECK N3`, `STOP N3`, and `ACK STOP N3`.
A stop is delivered only when the driver acknowledges it.
Missing acknowledgement or navigator loss goes to the owner immediately.

## Authority and recovery

The owner decides only within existing authority.
Escalate scope or accepted-contract change, destructive, irreversible, or security-sensitive action, and disagreement surviving one response.
Pair agreement never expands authority.
The captain retains merge authority.

On navigator loss or topology break, report it, restore the endpoint, then run `fm-pair-compose.sh recover <recovery.json>`, which re-verifies composition from each role's stable identity and appends the topology generation.
Never hand-edit a recorded pane into the evidence: Herdr reassigns a pane id on every move, and a refusal from that command means the pair is not proven, not that the evidence needs correcting.
The driver never stops implementing for want of a navigator: paired review lowers the risk of building the wrong thing rather than gating that it gets built.
Each gate carries a bounded wait, after which the driver goes solo, announces in durable history and its PR body that pair review fell, and records the gate outcome itself; open findings and every authority, scope, or destructive decision still come to you.
A solo PR arrives without independent review, so review it yourself or route it to one.
A recovered navigator reconciles current driver Git truth and durable history before another outcome.

## Parent owner contract

One completed clean navigator verdict on the exact current PR head satisfies the independent three-capability PR-review requirement. The three capabilities are: (1) `../matt/engineering/code-review/SKILL.md` — Standards and Spec axes applied in parallel sub-agents; (2) `../matt/productivity/writing-for-agents/SKILL.md` — loaded and applied by the navigator on every changed agent-facing document (skill, AGENTS.md, CLAUDE.md, docs/guidance an agent consumes); (3) `../classical-testing/SKILL.md` — proof sensitivity and strongest-authorized-real-path checks across every changed actor trigger.

Firstmate commissions a replacement independent reviewer when paired coverage is incomplete, solo, stale-head, or recovered without a completed exact-head final verdict. Any code change after the verdict invalidates it.

Navigator independence, immediate STOP authority, event-driven idle behavior, driver/navigator authority boundaries, and all existing recovery behavior are preserved. Each contract is kept in one owner: phase execution resides in navigator, acceptance/replacement ownership resides in parent. Use only a concise pointer elsewhere if required.
