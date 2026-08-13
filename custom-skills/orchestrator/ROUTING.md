# Execution routing

The routing branch of [`PROGRAMME.md`](PROGRAMME.md): the execution shape a task runs in, and how its worker profile is resolved.
Reached from its step 5, once the task cards exist.

Everything here routes a **child worker**.
The supervisor's own runtime, model, and effort are firstmate's to resolve once at [`SKILL.md`](SKILL.md) step 2, and they never propagate to a child.

This file owns task shape and risk, never a concrete runtime, model, provider, or fallback order.
Naming one here would freeze a moving catalog into a document nothing revalidates.

## Execution shape

Prefer **solo** when the trigger and seam are clear, the behavior is unambiguous, the change is isolated and reversible, and verification is deterministic.

Prefer a **pair** when the task carries a difficult or ambiguous seam, many dependencies, high failure impact, persisted-state or migration semantics, authentication, permission, or user-role behavior, lifecycle or concurrency semantics, destructive ownership change, multi-component composed failure, or semantic integration conflict.

The executable task decides, not its size and not its feature label: a large mechanical task may stay solo, and a small permission change may need a pair.
Use judgment on a borderline task and record the reason on its card.

A pair is one driver holding sole write custody of the task branch, and one navigator reading independently in an isolated copy at the driver's exact revision, forming its own source view before it reads the driver's plan.
[`paired-review`](../paired-review/SKILL.md) owns that gate; do not invent a second programme-specific review gate.
Pair agreement is review evidence; [`classical-testing`](../classical-testing/SKILL.md) still owns the completion claim.

## Resolving the worker profile

Classify the task, then hand that classification to the ordinary per-task dispatch procedure and let it name the runtime, model, and effort.

Record on each card the facts routing turns on: the seam and its clarity, the dependency shape, the blast radius, the evidence the task must produce, whether it needs strong reasoning or is bounded and well-understood, and the execution shape above.

`AGENTS.md` section 4 owns the dispatch precedence and the effort policy.
[`harness-adapters`](../../.agents/skills/harness-adapters/SKILL.md) owns which runtimes are verified and what each supports.
[`quota-array-dispatch`](../../.agents/skills/quota-array-dispatch/SKILL.md) owns choosing among candidates from current quota evidence.
Read them at dispatch time rather than carrying a remembered answer between tasks: availability, quota, and the model catalog all move underneath a programme that runs long.

Every card records the profile those owners resolved and one short reason.
The card is a record of that decision, not a second routing policy.

## Holding the capability line

- A tight quota is a reason to wait, to escalate, or to ask the captain.
  It is never a reason to quietly route demanding work to a weaker reasoning class; the dispatch owners above hold that line, and a programme that runs long is exactly where it erodes.
- Work labelled UI that also changes security, persistence, lifecycle, or a public contract routes by that harder seam and risk instead.
- A navigator runs on independent context and, at equal capability, a different provider or model family from its driver.
  Provider diversity never buys a weaker reviewer.
- When no candidate holds the capability the task needs, ask the captain rather than dispatching the nearest available one.

## Re-routing a task that grew

A worker that discovers an additional public seam, a hidden dependency, persisted state, a contract ambiguity, or materially higher risk stops before widening its task.
Revise the task, then re-route it: a bounded solo may become a stronger solo or a pair.
