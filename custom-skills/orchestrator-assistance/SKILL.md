---
name: orchestrator-assistance
description: Run a read-only, user-invoked awareness audit alongside a live programme orchestrator.
disable-model-invocation: true
---

# Orchestrator assistance

This skill guides a Luna Pi assistance session that independently audits a live programme orchestrator.
The captain or the orchestrator explicitly starts the session when extra awareness is wanted.
The session is read-only guidance and reports concise observations through the orchestrator's normal channel.
It does not replace the orchestrator, alter its authority, or run an automatic lifecycle.

## Operating boundary

Read the programme's own brief, scope records, decisions, current programme state, and project guidance before forming an opinion.
Use the programme and project records to discover project-specific paths, environments, acceptance evidence, and runtime requirements.
Keep the audit project-agnostic and do not assume a CFW layout, command, environment variable, or deployment shape.
Read the root and leaf `AGENTS.md` files relevant to the next worker task, including the project root and the nearest applicable leaf guidance.

Audit only at three moments:

- **Dispatch:** before a worker receives the next task.
- **Milestone:** when a worker reports a meaningful implementation or evidence milestone.
- **Final report:** when the orchestrator presents a task or programme completion claim.

Do not poll continuously or create a background process.
If a required record is missing, stale, contradictory, or unavailable, report the resulting uncertainty instead of filling the gap from memory.

## Audit loop

At each audit moment, use this order.

1. Read the current programme brief, target spec or scope records, applicable decisions, and current programme state.
2. Read the next worker's task and brief, then the relevant project root and leaf `AGENTS.md` files.
3. Compare the task and brief with the accepted scope, dependency frontier, required acceptance evidence, and project guidance.
4. At a milestone or final report, compare each completion claim with current Git, PR, and runtime evidence when that evidence is available.
5. Record each material observation using the finding schema below.
6. Deduplicate it against previously sent observations.
7. Send only a concise awareness notification through the orchestrator's normal channel.

The audit checks the orchestrator's reasoning without taking custody of its workflow.
Do not edit programme records, project files, worker branches, PRs, runtime state, or authority records.
Do not turn an observation into a stop command, approval gate, merge decision, business decision, or implementation instruction.

## Scope and completion

Treat target-spec coverage and target-spec completion as separate claims.

**Coverage** means every accepted requirement maps to a task, a required evidence item, or an explicit accepted exclusion.
A requirement with no owner, evidence route, or accepted exclusion is a coverage finding.
An explicit exclusion is evidence only when the programme's authority records actually accept it.

**Completion** means the accepted task slice and the final programme claim have evidence that matches the current source and state.
A complete coverage map does not prove that workers implemented the slice or that the final result works.
A worker report, green-looking summary, or old inspection is a claim until current evidence supports it.

At dispatch, check that the next task has an owner, a coherent dependency frontier, an acceptance slice, and a path to its required evidence.
At a milestone, check that the claimed change exists at the current branch or commit and that the claimed evidence belongs to that change.
At the final report, check both the coverage map and completion evidence for every accepted task slice and the final programme claim.

## Finding schema

Give every material finding a stable short id and these fields.

- `classification` - one value from the classification list below.
- `observed fact` - what the current records or source actually show.
- `expected contract` - the accepted scope, decision, brief, project rule, or evidence requirement that applies.
- `evidence path` - the exact file, record, commit, PR, command result, or runtime source used.
- `earliest preventable point` - the first dispatch, milestone, or final-report moment when the gap could have been caught or prevented.
- `consequence` - the concrete risk to the next task, accepted scope, evidence claim, or programme result.
- `confidence` - `high`, `medium`, or `low`, based on the strength and currency of the evidence.

Use `unproven` when the evidence cannot establish the observation or its owner.
Do not assign orchestrator blame merely because a gap exists.
Blame requires proof that the orchestrator controlled the relevant choice and could have prevented the omission at the stated moment.

## Classifications

- `orchestrator-error` means the orchestrator omitted or contradicted an accepted contract in a task, brief, dependency decision, evidence requirement, or programme record that it controlled and could have corrected.
- `worker-error` means a worker diverged from a clear, correctly handed-off task or contract, with evidence that the worker owned the divergence.
- `environment-or-tool` means a tool, runtime, credential, external service, or other environment condition caused the observed result.
- `scope-ambiguity` means the accepted records do not settle the required behavior, ownership, evidence, or boundary.
- `valid-decision` means the observed choice is deliberate, recorded, and consistent with the authority that owns it.
- `unproven` means the available evidence is insufficient to establish the fact, contract violation, cause, or owner.

A classification is a conclusion about evidence, not a demand for action.
When multiple classifications remain plausible, use `unproven` and name what evidence would distinguish them.
When a scope question is genuinely unsettled, use `scope-ambiguity` rather than treating a worker or orchestrator as wrong.
When a recorded decision explains the result and remains within authority, use `valid-decision` rather than reopening it.

## Evidence discipline

Prefer current source and current state over reports.
At a dispatch moment, inspect the actual task, dependency records, current branch bases, and relevant guidance rather than relying on a prior summary.
At a milestone or final-report moment, inspect the current Git diff and commit, the PR when one exists, and the runtime result when the programme requires runtime evidence.
Use only the evidence that the programme or project records make available and authorized.
Do not require a test, runtime check, or external artifact that the accepted contract does not require.
When an expected evidence source is unavailable, preserve the claim as `unproven` rather than silently lowering the acceptance bar.

## Notification and deduplication

Send notifications through the existing orchestrator conversation or routed reporting channel.
Do not create a new channel, inject a lifecycle command, or address a worker as an authority.
Keep each notification short and point to the durable evidence path for detail.

Use a stable finding id and suppress an unchanged repeat of the same finding.
Treat the classification, normalized observed fact, expected contract, and evidence identity as the finding fingerprint.
Send a follow-up only when the evidence, consequence, confidence, classification, or resolution materially changes.
Use `CLEAR` only when current evidence proves that a previously reported finding is resolved.

Use one of these notification forms:

```text
REMINDER [moment]: <one awareness point>; evidence: <path>
FINDING [id] <classification>: <fact>; expected: <contract>; earliest preventable: <moment>; consequence: <risk>; evidence: <path>; confidence: <high|medium|low>
CLEAR [id]: <current evidence resolves the finding>; evidence: <path>
UNPROVEN [id]: <claim cannot be established yet>; needed: <discriminating evidence>; evidence: <path or unavailable>
```

A `REMINDER` is a low-risk awareness note that does not allege an error.
A `FINDING` names a supported material discrepancy and its classification.
A `CLEAR` closes awareness for a prior finding without changing the orchestrator's workflow.
An `UNPROVEN` notification preserves uncertainty when a completion claim, cause, or owner lacks enough evidence.

## Examples

At dispatch, if the next worker has an accepted requirement but no task or explicit exclusion maps to it, send:

```text
FINDING [coverage-07] orchestrator-error: accepted requirement has no task, evidence item, or accepted exclusion; expected: complete target-spec coverage map; earliest preventable: dispatch; consequence: the programme may omit required work; evidence: <current scope record>; confidence: high
```

At a milestone, if a worker reports a completed change but the current branch has no corresponding diff and no verified PR or runtime artifact, send:

```text
UNPROVEN [milestone-03]: completion claim is not established by current source or available delivery evidence; earliest preventable: milestone; needed: current commit plus the required PR or runtime evidence; evidence: <task record and current branch>
```

At a final report, if every accepted requirement is mapped but one accepted task slice lacks its required evidence, send a coverage-clear reminder separately from the completion finding:

```text
REMINDER [final]: target-spec coverage is mapped; completion still depends on evidence for the accepted task slice; evidence: <coverage record>
UNPROVEN [final-02]: accepted task slice lacks required completion evidence; earliest preventable: final report; needed: <contract-defined evidence>; evidence: <task record>
```

## Simplest operating procedure

1. Read the programme brief, current scope, decisions, programme state, next worker brief, and relevant root and leaf `AGENTS.md` files.
2. Audit once before dispatch, once at a meaningful milestone, and once at the final report.
3. Compare scope, dependencies, acceptance evidence, guidance, and completion claims with current available evidence.
4. Classify, deduplicate, and send one concise awareness notification when a material observation exists.
5. Leave all authority, workflow, records, code, branches, PRs, and runtime actions with their existing owners.

## Non-goals

This skill does not dispatch, steer, stop, restart, or recover workers.
It does not approve scope, answer business decisions, authorize merges, or change the orchestrator's contract.
It does not edit code, programme records, project guidance, `AGENTS.md`, hooks, validators, watchers, daemons, or infrastructure.
It does not add a navigator, paired-review topology, continuous polling loop, or background service.
It does not require tests for this rules-only skill.
It does not convert an awareness notification into a gate or a command.
