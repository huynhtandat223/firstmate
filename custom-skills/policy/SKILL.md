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
Recognised roles are `worker` and `firstmate`.
If the marker is absent or unknown, resolve the role before loading a capability.

The role controls the role-allowed capability set and communication boundary.

- `worker` may use this policy and only the capability named by its delivery path.
- `firstmate` may use this policy and the ordinary Firstmate lifecycle owners.

A `worker` may also use the verification capability when it verifies expected behavior or claims a task done, and the `how` and `why` capabilities when their trigger is active.
Any role may use an interview or crystallization capability when the captain asks for it in that session.

A role may use a capability only when its trigger is active.
A capability can guide a step, but it cannot widen scope, change an accepted contract, merge, perform destructive or security-sensitive work, or turn planning into implementation.

## Trigger routing

Load only the exact file named by the first matching trigger, when the trigger occurs.

| Trigger | Exact capability |
| --- | --- |
| The captain explicitly chooses the plain interview form | `/home/dathuynh/codes/firstmate/custom-skills/matt/productivity/grill-me/SKILL.md` |
| The captain asks for an interview, design decision, or frontier round | `/home/dathuynh/codes/firstmate/custom-skills/matt/productivity/grilling/SKILL.md` |
| The captain asks to capture glossary or ADR decisions during grilling | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/grill-with-docs/SKILL.md`, then its exact domain-modeling companion |
| The captain explicitly asks to crystallize a spec | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/to-spec/SKILL.md` |
| The captain explicitly asks to crystallize dependency-aware tickets | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/to-tickets/SKILL.md` |
| When to-tickets or to-spec writes an issue body, after loading its crystallization procedure | `/home/dathuynh/codes/firstmate/custom-skills/ticket-template/SKILL.md` |
| An implementation worker in `cfw-modules` builds or changes a business page, a component definition, a primitive or a design token | `.agents/skills/cfw-frontend-development/SKILL.md` in that checkout |
| Verification of a task's expected behavior begins, or a completion claim is about to be made | `/home/dathuynh/codes/firstmate/custom-skills/classical-testing/SKILL.md` |
| A review task is opened | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/code-review/SKILL.md` |
| A diagnosis task is opened | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/diagnosing-bugs/SKILL.md` |
| A worker must change or judge existing behaviour it has not traced, or a placement or ownership question is open | `/home/dathuynh/.agents/skills/how/SKILL.md` |
| A worker or firstmate is about to change, remove or overrule something whose reason is not in front of it (a regression stays with the diagnosis row) | `/home/dathuynh/.agents/skills/why/SKILL.md` |

The vendored bytes under `custom-skills/matt/` are immutable.
Adapted skills (`how`, `why`, `arena`, `swarm`) are not vendored: each carries a `PROVENANCE.md` naming its upstream commit and what changed.
Read the exact path, preserve its procedure, and return here only for Firstmate authority and communication boundaries.

## Lazy loading and communication

The policy is read once per role session.
Matt capabilities are read only on their trigger, by exact absolute path.
Do not preload the catalog, copy Matt procedures into another document, or substitute a similarly named installed skill.

The captain owns product and engineering contract decisions and unresolved choices.
Workers report through Firstmate.
