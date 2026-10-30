# Provenance

- Upstream: `https://github.com/cursor/plugins`, path `pstack/skills/swarm`, commit `1ba91fc25c0977741dd0e267849e6234b037ed0a` (pstack 0.15.36, Lauren Tan).
- License: MIT. The upstream text is in `LICENSE` in this folder.

## Kept

The four phases (Frame, Fan out, Aggregate, Report), the partition, race and mixed shapes with a declared `first pass`, `rank all` or `best-of` rule, standalone briefs, `PASS` / `ISSUES` / `BLOCKED` with evidence and every provable issue listed, exact SHAs and method in each measuring brief, the single respawn before a gap, a gap that never counts as a pass, and the result table.

## Changed

- The Cursor todolist is the backlog item and its note.
- A worker is started by `bin/fm-spawn.sh` in its own local worktree (`--scout` when it writes no PR) and briefed through `bin/fm-brief.sh`, in place of a Cursor cloud or local background subagent; it reports in `data/<id>/report.md` plus a `done:` line.
- Worker models come from `data/captain.md` "Workers and models" in place of the upstream model rule file.
- Firstmate reads and records the usage meters before fan-out.
- A respawn is `bin/fm-control.sh <id> relaunch --note`, and a redirect is `bin/fm-send.sh`.
- A slice that touches company, 5001 or a Titan takes its `env:<name>` lease first (`bin/fm-lease.sh`).
- A UI slice serves its own Storybook and measures with cfw-modules' `verify-cfw` skill on target `url:<base>`, never on port 5010.
- Workers are torn down with `bin/fm-teardown.sh` after aggregation.
- The consolidated report goes to the backlog note, and to the captain when asked, in place of an in-chat report.
- The reference to the poteto-mode skill is dropped.
- The description is the firstmate trigger-index row.

## Dropped

The upstream model-selection and fallback rules for Cursor model slugs, and the cloud base-branch option.
