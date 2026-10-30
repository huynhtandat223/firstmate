# Provenance

- Upstream: `https://github.com/cursor/plugins`, path `pstack/skills/arena`, commit `1ba91fc25c0977741dd0e267849e6234b037ed0a` (pstack 0.15.36, Lauren Tan).
- License: MIT. The upstream text is in `LICENSE` in this folder.

## Kept

The six phases (Frame, Fan out, Cross-judge, Pick, Graft, Verify), the 3-6 criterion rubric written before fan-out, the judge from another model family than the parent, reading every candidate end to end, the pick rule, grafting by hand, convergence and reframing on wide divergence, and the synthesis note.

## Changed

- The Cursor todolist is the backlog item and its note.
- A seat is a worker started by `bin/fm-spawn.sh` in its own worktree and pane, in place of a Cursor background subagent; seats come from `data/captain.md` "Workers and models" in place of the upstream model rule file.
- A plan's seats are two Planner-charter scouts (claude `claude-opus-5-5` high, Pi `9route/cx/gpt-6.1-sol` high) that write their plan as their scout report and file nothing; a code seat commits on its own worktree branch and opens no PR.
- Firstmate reads and records the usage meters before fan-out.
- A dropout is relaunched once with `bin/fm-control.sh`, then dropped and noted.
- The judge is the ChatGPT reader (`chatgpt` skill) on a Claude firstmate, or a claude scout on a GPT firstmate.
- The graft for a plan is done by the plan's own spawned Planner, which files and then closes; the graft for code is folded by one ship worker into the feature's one PR.
- The synthesis note also records the usage readings, the rubric and each seat's model, and the seats are torn down with `bin/fm-teardown.sh`.
- The references to pstack principle skills (poteto-mode and others) are dropped; their rules are stated inline where the arena needs them.
- The description is the firstmate trigger-index row.

## Dropped

The upstream model-selection and fallback rules for Cursor model slugs.
