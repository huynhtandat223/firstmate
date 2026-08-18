# Upstream sync progress

This file is a temporary handover artifact for branch `fm/fm-upsync`.
Delete it in the final commit before the PR is merged.

## Merge identity

- First parent: `origin/main` at `37b95faa928dd21227940e1e308068af8cb3bb90`.
- Second parent: `upstream/main` at `d843712808658f26a7a3f248e632cb999864ca50`.
- Resolution rule used: upstream wins on upstream-owned code; deliberate fork behavior is carried forward onto the upstream implementation.
- `custom-skills/` was not touched by upstream and is byte-identical to `origin/main` in the index.

## Conflict ledger

All 29 paths are syntactically resolved and staged unless explicitly marked in-progress.

- `.agents/skills/harness-adapters/SKILL.md` - resolved
- `.agents/skills/stow/SKILL.md` - resolved
- `README.md` - resolved
- `VISION.md` - resolved
- `bin/backends/cmux.sh` - resolved
- `bin/backends/herdr.sh` - resolved
- `bin/fm-busy-lib.sh` - resolved
- `bin/fm-composer-lib.sh` - resolved
- `bin/fm-control-lib.sh` - resolved
- `bin/fm-decision-hold.sh` - resolved
- `bin/fm-spawn.sh` - resolved
- `bin/fm-teardown.sh` - resolved
- `bin/fm-test-run.sh` - resolved
- `bin/fm-tmux-lib.sh` - resolved
- `docs/agent-control.md` - resolved
- `docs/architecture.md` - resolved
- `docs/cmux-backend.md` - resolved
- `docs/configuration.md` - resolved
- `docs/decision-hold-lifecycle.md` - resolved
- `docs/herdr-backend.md` - resolved
- `skills/stow/SKILL.md` - resolved
- `tests/fm-backend-cmux.test.sh` - resolved
- `tests/fm-backend-herdr.test.sh` - resolved
- `tests/fm-composer-lib.test.sh` - resolved
- `tests/fm-control-relaunch.test.sh` - resolved
- `tests/fm-control.test.sh` - resolved
- `tests/fm-decision-hold-lifecycle.test.sh` - resolved
- `tests/fm-gotmp.test.sh` - resolved
- `tests/fm-spawn-dispatch-profile.test.sh` - resolved

## Resolution record

### Harness and lifecycle

- `.agents/skills/harness-adapters/SKILL.md`: upstream Cursor material won; the fork's `agy` model, launch, interrupt, exit, and resume facts were retained.
- `bin/fm-control-lib.sh`, `tests/fm-control.test.sh`: upstream Cursor mechanics won; `agy` remains a verified family with single Escape interrupt, `/exit`, no clear key, and no wiring artifact.
- `bin/fm-spawn.sh`: upstream executable pinning, Cursor support, relaunch transaction, and pooled-base refresh won. The fork's temporary-supervisor support and `agy` launch/model/effort support were carried forward. This file still needs the temporary-supervisor suite re-run after the freshening fixture correction.
- `bin/fm-teardown.sh`: upstream status-presentation retirement and Cursor sidecar cleanup won; fork supervisor-home cleanup, lifecycle serialization, and descendant lock protections remain.
- `bin/fm-busy-lib.sh`, `bin/fm-tmux-lib.sh`: upstream shared composer/Cursor behavior won. `agy` session-lock and delivery behavior remains elsewhere.

### Composer and runtime adapters

- `bin/fm-composer-lib.sh`, `tests/fm-composer-lib.test.sh`: upstream shared five-backend composer classifier won. It already subsumes the fork's blank-padded composer intent with locale-independent Unicode whitespace normalization; focused test passes.
- `bin/backends/cmux.sh`, `tests/fm-backend-cmux.test.sh`, `docs/cmux-backend.md`: upstream shared composer classifier won over the copied older cmux logic.
- `bin/backends/herdr.sh`, `tests/fm-backend-herdr.test.sh`, `docs/herdr-backend.md`: upstream shared classifier and Cursor submit transition won. Fork `agy` native-identity exception remains a narrow Herdr-only exception because a bare `>` must remain unknown fleet-wide. Fork payload-anchored delivery confirmation was restored for already-working Pi and agy panes, while upstream's footer transition remains the never-idle Cursor path. The complete focused Herdr suite now passes.

### Decisions, status, and watcher behavior

- `bin/fm-decision-hold.sh`, `tests/fm-decision-hold-lifecycle.test.sh`, `docs/decision-hold-lifecycle.md`: upstream decline, repair, keyed answer, and channel-binding paths won; fork archive fallback (`task_show_durable`) remains. Focused suite passes.
- Upstream `bin/fm-classify-lib.sh` and new `tests/fm-classify-decision-key.test.sh` landed cleanly. Both `needs-decision [key=x]: ...` and `needs-decision: [key=x] ...` pass.
- Upstream buried-status presentation, duplicate wake collapse, Pi hand-off protection, and re-arm durability landed cleanly. Focused `fm-pi-watch-extension` and `fm-wake-queue` pass.
- Fork awaited Pi test conditions (`37b95fa`) remain in ancestry and the focused Pi test passes.

### Docs and stow

- `VISION.md` and `docs/agent-control.md`: upstream versions won because fork PR #38 copied their earlier upstream contents without ancestry.
- `README.md`: upstream Cursor, ahoy, and stow text won; fork `agy` primary/crew support was added to requirements.
- `.agents/skills/stow/SKILL.md`, `skills/stow/SKILL.md`: upstream latest memory and inspect-before-write flows won. The fork's automatic secondmate cascade remains in the internal skill.
- Other docs conflicts use current upstream wording, with fork supervisor and agy statements preserved where still applicable.

### Known deliberate fork divergences checked

- `agy` launch/detection/session-lock/composer/control behavior: preserved, with Herdr composer verification still in progress.
- Blank-padded composer: preserved via upstream's stronger shared Unicode whitespace implementation.
- Live Pi session-lock liveness: preserved; existing test remains.
- Herdr lab leading `--session`: preserved in `bin/fm-herdr-lab.sh`.
- Whole-fleet JSON off jq argv: preserved in `bin/fm-fleet-snapshot.sh` and its oversized tests.
- Pruned captain holds from done archive: preserved through `task_show_durable`; focused suite passes.
- Awaited Pi watcher conditions: preserved; focused suite passes.
- `custom-skills/`: unchanged from `origin/main`.

## Baseline and verification evidence

The pre-merge baseline ran 142 of 143 tests in bounded batches.
`tests/fm-remote-secondmate-lifecycle-e2e.test.sh` was excluded on the captain's instruction because it leaked 187 orphaned `fm-remote-job-worker.sh` processes and drove load average above 80.
Do not run that file before or after the merge, and name the exclusion as a known suite defect in the PR body.

Pre-merge failures among the remaining 142:

- `tests/fm-backend-herdr-focus-flash-e2e.test.sh`: Part C never acquired a stable sleep child.
- `tests/fm-calm-pi-extension.test.sh`: installed Pi lacked `getMarkdownTransformers` in the renderer fixture.
- `tests/fm-remote-job.test.sh`: worker did not report ready after startup.

The originally expected Pi late-close race passed in this baseline.

Focused post-merge results:

- PASS: `fm-classify-decision-key`, `fm-send-resolve-key`, `fm-decision-hold-lifecycle`, `fm-control`, `fm-control-relaunch`, `fm-spawn-dispatch-profile`, `fm-spawn-pool-base-freshen`, `fm-composer-lib`, `fm-pi-watch-extension`, `fm-wake-queue`.
- PASS after correction: `fm-temporary-supervisor`; its fixture now supplies the local origin/default ref required by upstream pooled-base freshening.
- PASS after correction: complete `fm-backend-herdr`, including agy identity, busy Pi/agy payload confirmation, Cursor footer transition, and swallowed-Enter refusals.

Do not run `fm-test-run.sh --all`.
Use explicit bounded batches and always omit `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`.
Use a named non-default Herdr lab via `/home/dathuynh/.treehouse/firstmate-bd40d9/4/firstmate/bin/fm-herdr-lab.sh` for batches that drive real Herdr lifecycle.

## Open questions

1. Review `bin/fm-spawn.sh` for all `OWN_HOME` branches; the parser, metadata, relaunch adoption, no-treehouse path, and cleanup were manually restored and the focused supervisor suite passes.
2. Review docs for `agy` completeness. `AGENTS.md`, README, configuration, architecture, trace-context, remote doctor, bootstrap dispatch validation, remote secondmate control, and live liveness loop were updated, but a final `rg` should catch stale verified-harness lists.

## Next action

1. Stage all current edits and run `git diff --cached --check`.
2. Run `bin/fm-lint.sh` and `bin/fm-doc-audience-check.sh`.
3. Run bounded post-merge test batches excluding the leaking remote-secondmate file; compare failures with the baseline list above.
4. Commit the merge with both parents and push `fm/fm-upsync`.
5. Delete this file in a final normal commit before opening the PR.
