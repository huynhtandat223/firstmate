---
name: planner
description: >-
  Open a planner session for one scoped subject, with best-practice direction as
  its default recommendation, and publish a captain-approved spec or tickets
  only after explicit crystallization.
user-invocable: true
metadata:
  internal: true
---

# planner launcher

This launcher owns planner intake and lifecycle.
Read `/home/dathuynh/codes/firstmate/custom-skills/policy/SKILL.md` once for the worker contract and capability routing.

## Intake and launch

Open a planner only after the captain supplies one resolved project, a concrete scope, and the planning question and intended outcome in the captain's words.
Ask one concise question for any missing input.

Use the existing brief and spawn lifecycle:

1. Scaffold `bin/fm-brief.sh <task-id> <project> --scout`.
2. Fill `{SCOPE}` with the captain's scope and `{TASK}` with the planning question.
3. Identify `role=planner` and point the worker to `/home/dathuynh/codes/firstmate/custom-skills/policy/SKILL.md`.
4. Launch through `bin/fm-spawn.sh` with the resolved runtime and handle trust through `harness-adapters`.
5. Confirm the worker is processing the instructions, then hand the live session directly to the captain.

The planner worker reads policy, not this launcher.
The brief carries a pointer, not a copied planner procedure.

## Handoff and lifecycle

Tell the captain which project and scope are under discussion and where to talk to the planner.
After that handoff, step out of the conversation.
Do not answer for the captain, steer the planner, relay messages, or summarise the discussion.

Keep the planner session open until the captain explicitly returns or closes it.
Monitor lifecycle only: alive, waiting, published, returned, or failed.
A planner's quiet conversational wait is healthy.

Planning produces evidence and a captain-approved artifact.
It never authorises implementation; any implementation starts later through a separate captain-authorised lifecycle.
