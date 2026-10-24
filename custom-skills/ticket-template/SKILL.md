---
name: ticket-template
description: >-
  Apply when to-tickets or to-spec writes a GitHub issue body.
  Owns the issue sections, scenario fields, stable ids, and verification row form.
user-invocable: false
metadata:
  internal: true
---

# Ticket template

Use the selected to-tickets or to-spec procedure to crystallize the work; apply this template when writing its issue body.
This firstmate-owned skill owns the body format, including for specs.
Keep the vendored files under `custom-skills/matt/` unchanged.

## Issue body

Write these seven `## ` headings in this order.
Only these sections are read by the harness.

```markdown
## Context

<Why the work exists, in the owner's words; current facts with file:line change points.>

## Requirements

<What to build; file:line change points; accepted decisions; stop lines; out of scope.>

## Definition of done

Done when every user-visible scenario × width passes in the Tester's record on the deployed head, firstmate approves after that record, and the cleanup scenario passes; internal work requires a PR, green CI (or the repo checks where the repo has no CI), and the real run each scenario names.

## Scenarios

- [ ] <ID> WHEN <user action>, THE <page or tool> SHALL <observable result>.
  - page: <5001 page id, with `(draft)` after a draft row, or ->
  - widths: <1440, 390 or ->
  - controls: <role "visible label">; <role "visible label"> | -
  - env: <environment, account, tool>
  - proof: <the end-user action and what is saved>
  - data: <the exact record or input>
  - mock: none | <third-party source, who confirmed>
  - surface: user-visible | internal

## Mockup

<Link to the plan's mockup section or an image; none for internal work.>

## Links

<Plan; parent spec; Blocked by; related issues; PRs.>

## Decisions

<Each question, its answer, who answered, and when.>
```

Use the Definition of done paragraph above unchanged.
Context and Requirements name file:line change points; refresh stale references through a logged change.
A spec also carries its rollout acceptance lines in `## Scenarios` with the same shape.
The verify state belongs in the Tester's record and firstmate's `approved:` line, displayed by the board, rather than in the issue body.

## Scenario rules

Place the ID immediately after the checkbox.
Each ID matches `[A-Z]+[0-9]+`, is unique within its issue, and is never reused after a logged change.
Keep removed scenario IDs retired.
Write all eight fields in the order shown for every scenario.
For `surface: user-visible`, supply a page and widths other than `-`.
For a scenario with no widths, use `widths: -`.
Name the visible controls by role and label, or use `controls: -` where none apply.

## Verification record rows

Write one row per scenario × width, using `<ID>@-` when the scenario has no widths.
Choose one state from `pass`, `fail`, `pending`, and `retired`.
Use an evidence path or URL, or `-` when no evidence exists.
End the record with the Tester's timestamp and tested head.

```text
- <ID>@<width> | <line> | pass|fail|pending|retired | evidence: <path|url|->
verified: tester <epoch> head=<sha>
```

## Body check

Before filing, check all seven headings and their order, every scenario's eight fields, ID validity and uniqueness, and the page and widths of each user-visible scenario.
For a logged change, check the retired IDs and refreshed file:line references too.
Keep parser implementation and rewrites of existing issues outside template application unless separately assigned.
