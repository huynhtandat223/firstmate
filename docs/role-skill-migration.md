# Role skill layout

## Mapping

| Current location | Destination | Reason |
| --- | --- | --- |
| `.agents/roles/planner/contract/` | `.agents/roles/planner/` | Planner is a dispatched role. |
| `.agents/roles/orchestrator/contract/` | `.agents/roles/orchestrator/` | Orchestrator is a dispatched role. |
| `.agents/skills/paired-review/` | `.agents/skills/paired-review/` | The protocol supplies driver implementation and navigator guidance. |
| `.agents/roles/planner/design/` | `.agents/roles/planner/design/` | These are planner-only design references. |
| `.agents/skills/firstmate-coding-guidelines/` | `.agents/skills/firstmate-coding-guidelines/` | This is a narrow Firstmate authoring role reference. |
| `.agents/skills/firstmate-codexapp/` | `.agents/skills/firstmate-codexapp/` | This is a narrow Firstmate coordination reference. |
| `.agents/skills/firstmate-orca/` | `.agents/skills/firstmate-orca/` | This is a narrow Firstmate runtime reference. |

The shared operational skills remain under `.agents/skills/` because they are loaded by the primary during ordinary lifecycle work.

`ask-matt` is disabled: it has no project role path and is not exposed as a discoverable skill.

## Reference update rule

Primary instructions name an explicit role-contract path at dispatch.
Role workers read that path directly.
Pi discovers only `.agents/skills/`, so role contracts do not enter ordinary skill discovery.
Global handoff remains at `~/.agents/skills/handoff/SKILL.md`; this repository carries no duplicate.
