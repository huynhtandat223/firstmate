---
name: classical-testing
description: >-
  Agent-only verification contract for proving a task's expected observable behavior on the strongest authorized real path.
  Use before choosing how to verify a change, when a project declares TESTING_DATA.md, when the chosen verification level is blocked, and before claiming a task done.
user-invocable: false
metadata:
  internal: true
---

# classical-testing

This skill owns verification and completion evidence for one task.
Implementation order, architecture, framework choice, seam design, and whether the work is written test-first stay with the implementation and test-design capabilities the router names.

Passing unit tests are one input, never the completion claim.
A task is done when its expected observable behavior has been proven on the strongest authorized real path that its completion claim requires.

## Fidelity, authority, and sensitivity

- **Real** describes fidelity: the actual runtime, service, database, or persisted record rather than a substitute.
- **Test-owned** describes authority: the project has declared the asset available for verification.
- **Production** describes operational sensitivity.

One asset is routinely real, test-owned, and non-production at the same time.
Use such an asset as the default verification target; production-like appearance is not a blocker and never justifies a lower level.

## The project contract

Read the project's root `TESTING_DATA.md` before choosing or running verification whenever that file exists.
It is the project's authority for authorized environments, services, and databases, for business-valid records or selection rules, for allowed actions and mutations, for protected areas and forbidden operations, for observation paths, and for the cleanup and healthy final state that verification must leave behind.
It carries no credentials or secrets, so take those from the project's existing secret path.
Its shape is ordinary prose, lists, or tables, so read it for meaning rather than for a fixed schema.
It is read-only input to verification: changing it is a project change that follows the task's ordinary delivery path, and it is never a way to grant yourself authority.

Everything it declares is a testing asset, including real infrastructure and persisted data.
Work inside its boundary exactly: a declared action needs no further approval, and a protected area or forbidden operation stays untouched even when a stronger level would be convenient.

When the file is absent, task-specific authority from the brief or the captain supplies the same facts within that task's exact scope.
A missing file grants no new authority, and it does not let unit tests stand in for practical behavior that remains unproven.

## Verification ladder

Enter at the strongest level the task's completion claim requires, use the data the project contract declares, and descend only under the degradation rule below.
A claim about a persisted business workflow enters at level 1 or 2, while a claim about a pure function or a document enters lower, because runtime and persistence sit outside what it claims.

1. **Assembled system** exercised through its real runtime boundary with real test-owned data.
2. **Real service composition** exercised against the real database with real test-owned data.
3. **Real first-party component graph** exercised with representative persisted data.
4. **Public component boundary** exercised with representative data, available only when runtime and persistence are outside the completion claim.

Every level of this ladder is real, so a blocked level degrades only to the next real level below it.
Mocks, stubs, and fakes are not levels of this ladder.
Unit tests, type checks, lint, and static analysis stay valuable and are reported as themselves; they never carry the practical-behavior claim.

### Degradation

Lower the level one step at a time, and only after observing a concrete blocker at the current level.
An assumption, an expected difficulty, or an unattempted setup is not a blocker: attempt the level, then record what the attempt did.
Climb back to the stronger level and re-verify there once the blocker clears inside this task.

Record with every downgrade:

- the blocked level and the exact action attempted,
- the observed blocker evidence, such as the command, request, output, or error,
- the claims the remaining level still proves,
- the claims it does not prove,
- the residual risk that the completion claim now carries.

## Observation

Observe the outcome through a supported public interface whenever one exists, so an internal call never stands in for user-visible behavior.
Read a mutation back through that same interface.
Direct database or storage inspection supplements that evidence, and replaces it only when database state is itself the accepted boundary.

## Completion evidence

Record, for the behavior verified: the tested revision or artifact, the environment, the testing data or selection rule used, the action taken, the expected outcome, the observed outcome, the cleanup performed or final state, and the limitations.
Run the declared cleanup and leave the environment in the healthy final state the project contract requires.

## Verification pending

Report `verification pending` when no authorized level proves the expected behavior, and treat the task as not done.
Name what remains unproven, the blocker that stopped the strongest attempted level, and what would prove it: an authorization, an environment, or data the project has not declared.
A weaker check that passed never converts a pending verification into a completion claim.
