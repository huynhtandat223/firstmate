---
name: kanban-v2
description: >-
  Apply before a worker or firstmate writes to a task the owner follows on the Kanban v2 board, or when a part of its task page on Dev 5001 shows the wrong thing.
  Owns which command writes each part of the task page, the common cases, and the owner's rules for a worker's status each turn and one pull request per task.
user-invocable: false
metadata:
  internal: true
---

# Kanban v2 task page

The owner follows each task on the page `firstmate.board` of Dev 5001, not in a worker's pane: what the page does not show does not reach him.
Each part of the page reads the task record that `bin/fm-task.sh` writes, or the questions `agent-ask` posts; their `--help` owns every flag and refusal.

## The owner's rules

- Each turn, a worker writes a 2-line status on the task: what is done; what waits on whom.
  Long reports stay comments or the done document.
- One task has one pull request; a second pull request is its own subtask, which firstmate files.

## What each part reads

| Part | Reads | Written by |
| --- | --- | --- |
| Why | the `## Context` section of the newest Description | `describe` |
| Acceptance | the scenario check rows, a chip per width, counted as N of M passed | `describe` seeds them while the task holds none; `rows` re-syncs them; `check` sets each result |
| Delivery | the stage, the PR URL, the newest `pr` event's merged flag, a deploy after the newest done, and whether every row passed | `event pr` or `done --pr-url` (PR open); `event pr --merged` (Merged); `event deploy` (Live); `check` (Verified) |
| Solution | the newest plan, one card per heading `## How it is used`, `## How it is built`, `## How it is tested` (a plan without them is drawn whole), its pictures in the first card, and the owner's decision | `plan`; the owner's Approve or Request changes on the tab runs `plan-decision` |
| Latest | the note of the task's newest event, its first 300 characters | the `--note` of any write |
| Chat | comments with their images, threads at a quoted passage, and the task's open `agent-ask` cards, surveys among them | `comment`; `agent-ask` run with `FM_TASK_ID` set to the task |
| Needs you | open `agent-ask` questions of kind decision, approval or action, and each task whose Solution waits for the owner's decision | `agent-ask`; `plan` |
| Subtasks | the task's parent and child links, and its link events | `create --after`, `link`; `event link` |

Why, Acceptance, Delivery and Latest are cards on the Overview tab; Needs you is a view of the board, outside the task.

## Latest is the newest note

Any newer event replaces the status, and one with no note empties it: a `describe`, a bare `pr` event, a Tester's `check` and a comment all do.
`block --reason`, `ask --question` and `done --summary` stay off Latest; only `--note` reaches it.
A `done --pr-url` and an `ask --next-actor owner` each write a wait event right after themselves, so Latest then shows that wait's note.

## Common cases

| When | Run | Shows on |
| --- | --- | --- |
| A worker's turn ends | the terminal call, with the 2-line status as its `--note` | Latest |
| The owner owes one decision | `agent-ask` with its `--kind`; `fm-task.sh ask` puts its question on the task's Chat, outside Needs you | Needs you and Chat |
| The owner owes a round of questions | one `agent-ask --payload-file` survey | the task's Chat only |
| The task is about to be built | `plan` with the Solution and its pictures | Solution, and Needs you until the owner decides |
| A pull request opens | `event pr --pr-url`, or `done --pr-url` when the turn ends | Delivery: PR open |
| A pull request merges or deploys | `event pr --merged`, then `event deploy --head`; firstmate's merge hook and deploy verify write them, and firstmate writes any they missed | Delivery: Merged, Live |
| The scenarios of a Description that already has rows change | `rows`, because a later `describe` keeps the old rows | Acceptance |
| A picture or evidence for the owner | `comment --image` | Chat |
| The work splits | `create --after PARENT` for a new task, `link` for an existing one | Subtasks of both tasks |
| The owner asks in a thread | `comment --reply-to`, with `--outcome` to propose how it ends | the thread in Chat |
| A task needs another document | `plan` for the Solution, `done --document` for a report, because every `describe` replaces the Description | Solution, or the Documents card |
