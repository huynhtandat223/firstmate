---
name: classical-testing
description: >-
  Classical proof design and completion verification for changed behavior: map every changed trigger point, derive the smallest proof set that is sensitive to it, and prove the accepted claim on the strongest authorized real path.
  Use before implementing or choosing tests for a change, when selecting, reusing, amending, or adding a behavior test, when a project declares TESTING_DATA.md, when an authorized real verification level is blocked, and before claiming a task done.
user-invocable: false
metadata:
  internal: true
---

# classical-testing

This tracked skill owns proof design and completion evidence for one task.
Architecture, implementation order, framework choice, and whether the work is written test-first stay outside this skill.

Passing unit tests are one input, never the completion claim.

## Phase 1 - Classical proof design

Run this phase before implementation or test selection.

### Trigger-point proof map

Produce this table before changing code or choosing tests, one row per changed trigger point:

| ID | Triggering actor | Trigger point | Inputs and preconditions | Dependencies set up or invoked | Expected effect | Supported public observation or readback |
| --- | --- | --- | --- | --- | --- | --- |

A **trigger point** is the supported boundary where an actor or event starts changed behavior.
An actor is a person, API client, service, scheduler, queue, CLI operator, migration runner, or recovery process.
A test runner, an internal handler, a method call, and a dependency invocation are mechanisms inside a trigger rather than trigger points of their own.

A **seam** is a supported surface the proof touches: the **public seam** where the actor starts the behavior, and the **observation seam** where the effect is read back.

Dependency setup belongs to the current trigger's preconditions.
Setup or configuration earns its own row only when that setup or configuration behavior itself changed.
Several endpoints or handlers share one row when actor, initiation contract, effect, and observation are the same.

The map is complete when every accepted changed behavior belongs to a trigger row, and every row carries changed behavior.

### Existing coverage before new coverage

For each trigger row, read the existing tests at that exact seam: their setup, action, observation path, and assertions.
A similar name, endpoint, fixture, or green result is not proof.

Prefer, in this order:

1. **Reuse** the test unchanged when it already proves the exact changed claim with a sensitive assertion.
2. **Amend** it when the seam and setup are right and a case or an assertion is missing.
3. **Add** a test when existing coverage cannot prove the claim cleanly.

A **sensitive assertion** states what observable result would differ if the changed behavior were absent or wrong.

An assertion that fails that test in both directions is a **change detector**.
It passes while the behavior is wrong, because it binds to something the behavior does not determine - a status code, a call count, the presence of a string.
It fails while the behavior is right, because it binds to an internal shape a refactor moves.
A change detector reports that the code changed; it never reports that the behavior is correct, and a green suite of them is not evidence.

### Classical-case table

Seam classes, worked once each.
Map the row onto the closest one; a row that matches none still fills the same path.

Each example closes with the seam reached for by default.
The reason that seam fails is the lesson.

#### A customer-facing API change

- Preconditions: a test-owned customer holds a cart of two units of a stocked item; the service is reachable at its HTTP boundary; the customer's token comes from the project's secret path.
- Trigger: `POST /orders` with that cart, sent as the customer.
- Effect: the order is created and the two units are reserved.
- Observation: `GET /orders/{id}` as the same customer.
- Sensitive assertion: the readback state is `reserved` and the item's available count dropped by two.
  A `201` alone passes whether or not the reservation happened.
- Cleanup: `DELETE /orders/{id}` through the supported cancel path, then re-read to confirm the units returned.
- Rejected seam: the order service's create method - a mechanism inside this trigger, skipping the routing, authorization, and validation the customer actually crosses.

#### An operator-run command

- Preconditions: the item's available count has drifted from its reservations; the command is on `PATH` and runs as the operator; no other run is in flight.
- Trigger: `inventory reconcile --item <id>`, run as the operator.
- Effect: the available count is corrected and the correction is recorded.
- Observation: `inventory show --item <id>`, the supported read command, plus each run's exit code.
- Sensitive assertion: the read command reports the corrected count, both runs exit 0, and a second reconcile leaves the count unchanged and still exits 0.
  A drifted, an uncorrected, and a twice-corrected count each fail it.
- Cleanup: restore the seeded drift through the supported path, then re-read to confirm the original state.
- Rejected seam: the command's library function, reached by sourcing it - a surface no operator crosses, which a rename breaks while the operator's contract is untouched.

#### An unauthorized dependency

- Preconditions: the project's testing contract does not authorize the third-party payment provider, and the case records that reason.
  Everything first-party stays real.
  The provider is doubled at its own HTTP boundary and answers one call with a decline.
- Trigger: `POST /orders/{id}/confirm`, sent as the customer.
- Effect: the order moves to declined and its reservation is released.
- Observation: `GET /orders/{id}` as the same customer.
- Sensitive assertion: the readback carries the declined state, the provider's decline reason, and a restored available count.
  A swallowed error surfaces as a generic failure and fails all three.
- Cleanup: cancel the order through the supported path; the double falls with the case.
- Limitation: proves the project's decline handling against the declared provider response, not the provider integration.
- Rejected seam: the first-party payment component - doubling it erases the mapping between the provider's answer and the order state, which is the changed behavior itself.

#### A host-start bootstrap and seed-data path

- Preconditions: persistence is isolated and test-owned, with no competing host using it.
  The assembled application can be started through `.NET WebApplicationFactory` against that same persistence.
- Trigger: start the assembled host through `WebApplicationFactory`; application host startup runs the bootstrap or initializer that creates the default data.
  The changed trigger is host startup, not a direct seeder or service-method call.
- Effect: the default records exist with their expected values, and startup is safe to repeat against the existing isolated data.
- Observation: use the supported public API, query, or other readback seam exposed by the started host.
- Sensitive assertion: the first host's public readback finds the expected records; dispose it, restart a fresh host against the same isolated data, and the readback still finds the correct values with exactly one row for each seeded identity.
  Missing initialization, wrong defaults, or duplicate seed rows fails the assertion.
- Cleanup: dispose every host and remove the isolated persistence through the test-owned cleanup path; make cleanup failure visible.
  The final healthy state is no running test host and no retained test data.
- Limitation: proves the assembled host-start path at verification Level 1 with test-owned persistence, including the registered startup composition and initializer.
  It does not prove production deployment, multi-instance startup races, or production data migration.
- Rejected seam: calling the seeder directly or resolving a service from DI - both skip host composition, registration, startup ordering, and initializer execution.

Produce this table after the proof map:

| Trigger ID | Case | Initial state and dependency form | Invocation and inputs | Expected observation or readback | Sensitive assertion | Concrete risk evidence | Reuse, amend, or add | Determinism and cleanup | Limitation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

Every row forms one complete proof path:

`initial state and dependencies -> trigger -> effect -> public observation -> sensitive assertion -> cleanup`

### Case budget

Two or three net-new cases per changed trigger point is the **lean default** after reuse and amendment.
It is neither a minimum nor a hard cap: add no case merely to reach it, and exceed it when a distinct changed claim or an accepted concrete risk is still unproved, naming that claim or risk in the row.
Give each claim its own case rather than hiding several inside one opaque parameterized case.

A simple stateless trigger commonly needs one public happy case, plus one common refusal when a validation, authorization, dependency, or regression contract supplies the evidence.
A persisted trigger commonly needs a happy invocation with public readback or downstream observation, plus one concrete duplicate, retry, dependency-failure, or regression case when evidenced.
Readback belongs inside the happy case rather than in a case of its own.

Bug regression and safety are overlays on those cases rather than competing categories:

- A bug regression distinguishes pre-fix behavior from post-fix behavior at the narrowest supported public seam whenever that is feasible.
- A changed safety invariant carries its own positive, refusal, or regression evidence, and authorization, privacy, destructive action, concurrency, idempotency, migration, and irreversible behavior each keep that evidence.
  The lean default never erases a distinct accepted safety invariant.

### Real dependencies by default

Use every authorized, test-owned real dependency.

A focused automated case may replace one with a **controlled double** only when it records one of these facts:

- the project testing contract or the task authority does not authorize the real dependency;
- invoking it would cause an unauthorized external or destructive effect;
- no test-owned instance is available after an attempted setup;
- its state cannot be seeded, reset, or isolated for repeatable execution;
- the case must induce a dependency failure that the real dependency cannot produce safely and deterministically; or
- the project's declared suite contract excludes that dependency type.

The case records the dependency, the applicable reason, the evidence, and the limitation.
Place the double at that dependency's supported boundary rather than at an internal collaborator, and give it only the dependency responses the case needs.

A doubled case proves behavior against the declared dependency response.
It does not prove real integration.
When the accepted completion claim includes that integration, Phase 2 exercises the strongest authorized real path or reports `verification pending`.
When a double represents an external contract, use the project's existing adapter contract-test convention to detect drift; new contract-test plumbing waits for a changed contract or an established project requirement.

### Observation, determinism, and cleanup

Verify observable output or state.
Verify an interaction only when the interaction is itself the accepted behavior and no supported state or output reveals it - a cache hit, an outbound notification - and record that reason in the row.

- Drive time-dependent behavior with a controlled clock.
- Wait for async behavior with a callback, a completion signal, or bounded polling; a bare sleep is not proof.
- Give each case an isolated starting state, rebuild state or run verified cleanup afterwards, and make a cleanup failure visible rather than silent.

Phase 2 still owns the final healthy state.

## Phase 2 - Completion verification

A task is done when its expected observable behavior has been proven on the strongest authorized real path that its completion claim requires.

### Fidelity, authority, and sensitivity

- **Real** describes fidelity: the actual runtime, service, database, or persisted record rather than a substitute.
- **Test-owned** describes authority: the project has declared the asset available for verification.
- **Production** describes operational sensitivity.

One asset is routinely real, test-owned, and non-production at the same time.
Use such an asset as the default verification target; production-like appearance is not a blocker and never justifies a lower level.

### The project contract

Read the project's root `TESTING_DATA.md` before choosing or running verification whenever that file exists.
It is the project's authority for authorized environments, services, and databases, for business-valid records or selection rules, for allowed actions and mutations, for protected areas and forbidden operations, for observation paths, and for the cleanup and healthy final state that verification must leave behind.
It carries no credentials or secrets, so take those from the project's existing secret path.
Its shape is ordinary prose, lists, or tables, so read it for meaning rather than for a fixed schema.
It is read-only input to verification: changing it is a project change that follows the task's ordinary delivery path, and it is never a way to grant yourself authority.

Everything it declares is a testing asset, including real infrastructure and persisted data.
Work inside its boundary exactly: a declared action needs no further approval, and a protected area or forbidden operation stays untouched even when a stronger level would be convenient.

When the file is absent, task-specific authority from the brief or the captain supplies the same facts within that task's exact scope.
A missing file grants no new authority, and it does not let unit tests stand in for practical behavior that remains unproven.

### Verification ladder

Enter at the strongest level the task's completion claim requires, use the data the project contract declares, and descend only under the degradation rule below.
A claim about a persisted business workflow enters at level 1 or 2, while a claim about a pure function or a document enters lower, because runtime and persistence sit outside what it claims.

1. **Assembled system** exercised through its real runtime boundary with real test-owned data.
2. **Real service composition** exercised against the real database with real test-owned data.
3. **Real first-party component graph** exercised with representative persisted data.
4. **Public component boundary** exercised with representative data, available only when runtime and persistence are outside the completion claim.

Every level of this ladder is real, so a blocked level degrades only to the next real level below it.
Mocks, stubs, and fakes are not levels of this ladder, and a Phase 1 controlled double stays reported as itself.
Unit tests, type checks, lint, and static analysis stay valuable and are reported as themselves; they never carry the practical-behavior claim.

#### Degradation

Lower the level one step at a time, and only after observing a concrete blocker at the current level.
An assumption, an expected difficulty, or an unattempted setup is not a blocker: attempt the level, then record what the attempt did.
Climb back to the stronger level and re-verify there once the blocker clears inside this task.

Record with every downgrade:

- the blocked level and the exact action attempted,
- the observed blocker evidence, such as the command, request, output, or error,
- the claims the remaining level still proves,
- the claims it does not prove,
- the residual risk that the completion claim now carries.

### Observation

Observe the outcome through a supported public interface whenever one exists, so an internal call never stands in for user-visible behavior.
Read a mutation back through that same interface.
Direct database or storage inspection supplements that evidence, and replaces it only when database state is itself the accepted boundary.

### Completion evidence

Record, for the behavior verified: the tested revision or artifact, the environment, the testing data or selection rule used, the action taken, the expected outcome, the observed outcome, the cleanup performed or final state, the limitations, and any controlled doubles Phase 1 used.
Run the declared cleanup and leave the environment in the healthy final state the project contract requires.

### Verification pending

Report `verification pending` when no authorized level proves the expected behavior, and treat the task as not done.
Name what remains unproven, the blocker that stopped the strongest attempted level, and what would prove it: an authorization, an environment, or data the project has not declared.
A weaker check that passed never converts a pending verification into a completion claim.
