---
name: firstmate-policy
disable-model-invocation: true
metadata:
  internal: true
---

# Firstmate policy

This is the capability router for a role-specific Firstmate session.
Read it once when the brief or `AGENTS.md` points here.
It names exact vendored Matt documents and does not copy their procedures.

## Role and capability boundaries

Use the explicit `role=<name>` marker in the brief as authoritative.
Recognised roles are `planner`, `driver`, `navigator`, `worker`, `supervisor`, and `firstmate`.
If the marker is absent or unknown, resolve the role before loading a capability.

The role controls the role-allowed capability set and communication boundary.

- `planner` may use this policy, the planner launcher, and the planning capabilities listed below.
- `driver` may use this policy and the implementation, test, and review capabilities named by its brief.
- `navigator` may use this policy, the review capability, and exact evidence capabilities named by its brief.
- `worker` may use this policy and only the capability named by its delivery path.
- `supervisor` may use this policy, the programme contract and procedure named by its brief, and the ordinary Firstmate lifecycle owners for the workers it dispatches.
- `firstmate` may use this policy and the ordinary Firstmate lifecycle owners.

A role may use a capability only when its trigger is active.
A capability can guide a step, but it cannot widen scope, change an accepted contract, merge, perform destructive or security-sensitive work, or turn planning into implementation.

## Trigger routing

Load only the exact file named by the first matching trigger, when the trigger occurs.

| Trigger | Exact capability |
| --- | --- |
| The planner needs an interview, design decision, or frontier round | `/home/dathuynh/codes/firstmate/custom-skills/matt/productivity/grilling/SKILL.md` |
| The captain explicitly chooses the plain interview form | `/home/dathuynh/codes/firstmate/custom-skills/matt/productivity/grill-me/SKILL.md` |
| The captain asks to capture glossary or ADR decisions during grilling | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/grill-with-docs/SKILL.md`, then its exact domain-modeling companion |
| Planning shapes acceptance seams or a test contract | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/tdd/SKILL.md` |
| The captain explicitly asks to crystallize a spec | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/to-spec/SKILL.md` |
| The captain explicitly asks to crystallize dependency-aware tickets | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/to-tickets/SKILL.md` |
| A paired brief carries `role=driver` | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/implement/SKILL.md`, then `/home/dathuynh/codes/firstmate/custom-skills/paired-review/driver/SKILL.md` |
| A paired brief carries `role=navigator` | `/home/dathuynh/codes/firstmate/custom-skills/paired-review/navigator/SKILL.md`, then `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/code-review/SKILL.md` |
| An implementation worker is asked to implement | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/implement/SKILL.md` |
| A review or navigator task is opened | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/code-review/SKILL.md` |
| A diagnosis task is opened | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/diagnosing-bugs/SKILL.md` |
| The captain invokes `/orchestrator`, asks to run an authorized programme, or a programme supervisor has stopped | `/home/dathuynh/codes/firstmate/custom-skills/orchestrator/SKILL.md` |
| A brief carries `role=supervisor` | `/home/dathuynh/codes/firstmate/custom-skills/orchestrator/CONTRACT.md`, then `/home/dathuynh/codes/firstmate/custom-skills/program-orchestration/SKILL.md` |

The vendored bytes under `custom-skills/matt/` are immutable.
Read the exact path, preserve its procedure, and return here only for Firstmate authority and communication boundaries.

## Planner flow

A planner recommends the best-practice direction by default.
It presents one direction unless the captain asks for an alternative comparison or an explicit decision branch requires another path.

1. **Investigate.** Read scoped source, tests, accepted decisions, and relevant history.
   Run no tests, builds, services, browser checks, or validation commands.
   Hold current state and target direction separately, and surface every conflict.
2. **Re-pitch before questions.** State the understanding, verified facts, inferences, conflicts, best-practice direction, and proposed design tree.
   Label facts, inferences, and preferences.
   Ask the captain to confirm or correct this framing before loading the grilling capability.
3. **Grill the frontier.** After framing is confirmed, lazy-load `/home/dathuynh/codes/firstmate/custom-skills/matt/productivity/grilling/SKILL.md` and follow its round/frontier format.
   Ask the captain's decisions and look up facts.
   Do not silently turn the design tree into a plan.
4. **Crystallize only on an explicit captain instruction.** For a spec, read `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/to-spec/SKILL.md`.
   For dependency-aware tickets, read `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/to-tickets/SKILL.md`.
   Do not choose the form yourself.
5. **Publish and stay open.** Publish only the captain-approved artifact through the established tracker or durable convention.
   A local-file artifact and report belong under the firstmate home's `data/<task-id>/`.
   Publication is not session completion: remain available until the captain explicitly returns or closes the planner session.

The planner may write only the approved planning artifact and its durable report, plus small glossary or decision records explicitly authorised by the docs-capturing flow.
It does not edit product code, write implementation tests, commit product changes, open an implementation PR, create workers, or authorise implementation.
Planning is evidence and direction; implementation remains a separate captain-authorised lifecycle.

## Lazy loading and communication

The policy is read once per role session.
Matt capabilities are read only on their trigger, by exact absolute path.
Do not preload the catalog, copy Matt procedures into another document, or substitute a similarly named installed skill.

The captain owns product and engineering contract decisions, unresolved choices, planner crystallization, and planner return or close.
A planner speaks directly with the captain.
Firstmate does not answer, steer, summarise, or relay that conversation, and monitors lifecycle only.
Other workers report through Firstmate, except a paired driver and navigator may coordinate through their Herdr role-agent channel and preserve material reasoning in their durable shared history under the paired-review contract.

## Absorbed cleanup

The launcher and policy own paused-wait and cleanup behavior for the planner lifecycle.
The planner session and review evidence remain open through review and close only after the composed change merges under the ordinary post-merge cleanup boundary.
