---
name: arena
description: Load when the captain says arena, or before dispatching a main task's plan, a component API or a page layout that one attempt would lock into the wrong shape; read the usage meters first and record them in the backlog note.
metadata:
  internal: true
---

# Arena

Firstmate runs the arena, because only firstmate starts other sessions.
Several seats attempt the same artifact, a judge from another model family scores them against a rubric, firstmate picks a base, and the strongest parts of the other candidates are grafted into it by hand.

The backlog item and its note are the arena's todolist.
Before launching anything, write one entry per phase in that note (Frame, Fan out, Cross-judge, Pick, Graft, Verify), and mark each entry as its phase completes.

## Phase A: Frame

Every seat gets the same task text, so the task text is the contract.

1. State the artifact each seat produces.
2. Write the rubric before fan-out: 3-6 concrete, gradeable criteria for success on this task, recorded in the backlog note.
   The rubric is the picker's and the judge's tool; seats see only the task.
3. Read the usage meters before fan-out and record each reading in the backlog note: the Claude status line (5 h and week) of every Claude account a seat may use, and the 9router quota (the "Model quota truth" paragraph in `data/5001-ops/README.md`).
   A seat whose account is at its limit moves to another account of the same family, said in the note.
4. Pick the seats from `data/captain.md` "Workers and models", from at least two model families, never Fable or `cx/gpt-6-astra`.
   A seat is a worker started by `bin/fm-spawn.sh`, with its own worktree, pane and `state/<id>.meta`.
   - For a plan, the seats are two scouts briefed with the Planner charter: claude `claude-opus-5-5` high on Claude3 or Claude4, and Pi `9route/cx/gpt-6.1-sol` high.
     Each writes its plan as its scout report, `data/<id>/report.md` (the report is the plan), and files nothing: no issue, PR or comment.
   - For code, each seat is a scout that commits its candidate on the local branch of its own worktree and names that commit in `data/<id>/report.md`; no seat opens a PR.
   - Add seats when the arena covers several design directions.
     Use the same model several times when the work is generation-bound rather than judgment-sensitive.
5. Scaffold each seat's brief with `bin/fm-brief.sh <id> <project> --scout`.
   `## Captain's intent` holds the task text; `## Firstmate spec` names the seat's output (its report, or for code its commit) and asks for a short rationale naming the alternatives it considered and what it rejected.

## Phase B: Fan out

Start every seat in the same turn, one `bin/fm-spawn.sh <id> <project> --scout --harness <h> --model <m> --effort <e>` per seat, and supervise each like any other worker.
A seat that stops without its output is relaunched once with `bin/fm-control.sh <id> relaunch`.
After a second miss it is dropped: the arena proceeds with the remaining seats and the note records the dropout.

## Phase C: Cross-judge

When every seat has reported or dropped, start one judge.
The judge is never from the parent firstmate session's model family.
On a Claude firstmate the judge is the ChatGPT reader (`chatgpt` skill); on a GPT firstmate it is a claude `claude-opus-5-5` scout that changes nothing.
If no judge from another family can run, skip the judge, pick alone in Phase D, and say so in the synthesis note.

The judge sees the rubric and the candidates by label (Seat A, Seat B), never by model.
It scores each candidate criterion by criterion and recommends a base with its rationale.
It runs while firstmate reads in Phase D.

## Phase D: Pick

Read every candidate end to end before picking.
Score each against the rubric criterion by criterion, then compare with the judge.
Agreement on the base confirms the pick.
Disagreement means one reader is biased or the rubric was ambiguous: read both rationales before deciding.

Pick the base a future maintainer can extend most easily without breaking invariants.
When two candidates tie, prefer the cleaner boundary or the smaller API.

## Phase E: Graft

Walk each other candidate once more for what is worth porting into the base, usually one or two things per candidate.
Graft by hand so the result stays coherent under one mental model; pasting sections side by side is not a graft.

- For a plan, the plan's own spawned Planner grafts and files: a fresh `bin/fm-spawn.sh --scout` with the Planner charter, briefed with the base seat's report, the chosen grafts with their source reports, and the rubric.
  It closes after filing, with `bin/fm-teardown.sh`.
- For code, one ship worker folds the base and the grafts into the feature's one PR.

When the candidates converge on one shape, that is strong agreement: note it and ship the consensus shape without a graft.
When they diverge widely, Phase A was under-specified: reframe and re-run rather than averaging the divergence.

## Phase F: Verify

Verify the grafted artifact like any other output of its kind.
A problem the arena missed means Phase A was wrong (reframe and re-run) or a candidate caught it and the graft missed it (return to Phase E).

After the synthesis note is written, tear down every seat and judge scout with `bin/fm-teardown.sh`.

## Output

One grafted artifact and one synthesis note at `data/<arena-id>/synthesis.md`, which the backlog note links.
The synthesis note names:

- the usage readings and the rubric, both as written before fan-out;
- each seat's harness, model, effort and account, and its report path;
- the base and why;
- the judge's verdict and whether it agrees with firstmate's pick, or that the judge was skipped;
- each graft with its source seat, and what was rejected and why;
- any convergence or dropouts;
- the verification result.
