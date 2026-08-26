---
name: make-test
description: "Create high-quality tests for real behavior, domain rules, integrations, data correctness, and regressions. Use when adding, improving, or designing tests in an existing codebase."
---

# Make Test

Create tests that verify meaningful behavior rather than merely increasing coverage numbers.

The goal is to produce tests that are understandable, deterministic, maintainable, and useful when the implementation changes.

## Core Rules

- Test observable behavior, domain rules, contracts, invariants, and failure modes.
- Prefer the lowest test level that can catch the behavior: unit, integration, contract, or end-to-end.
- Prefer real dependencies when their behavior is part of correctness.
- Do not add duplicate coverage.
- Do not invent expected behavior when correctness is ambiguous.
- Do not modify production code unless the user explicitly asks for an implementation fix.
- Follow the repository's existing test framework, naming, fixtures, and execution conventions.

## Defaults

Use the project's existing tooling when available. Otherwise use:

| Language | Default framework |
| --- | --- |
| Python | `pytest` |
| Go | `testing` |
| Rust | `cargo test` |
| Java/Kotlin | JUnit |
| JavaScript/TypeScript | Vitest |
| .NET | xUnit |

For external services, prefer Testcontainers when integration behavior matters and Docker is available. Use Docker Compose when several tightly coupled services are easier to operate together. Do not introduce infrastructure for a pure unit test.

## User-Question Gate

Be autonomous by default. Do not ask for information that can be determined from the repository, existing tests, documentation, fixtures, or domain code.

Ask the user only when the test's correctness depends on information that cannot be established from the codebase, such as:

- external data or production examples that must be supplied;
- gold, reference, or expected-output data that must be approved;
- genuinely ambiguous domain rules or expected behavior;
- a business decision with multiple valid outcomes;
- permission to use, minimize, anonymize, or commit sensitive data;
- an unavailable external service or required test infrastructure.

Before asking, inspect the repository thoroughly. Ask focused questions and explain exactly which correctness decision or missing data the answer affects. Never ask merely because a detail is inconvenient to discover.

## Workflow

### 1. Understand the request

Identify:

- the behavior or bug being tested;
- the public entry point or user-visible outcome;
- the expected result and important invariants;
- whether the request is a new test, a regression test, broader coverage, or a test refactor.

### 2. Inspect the repository

Find and read:

- existing tests for the relevant behavior;
- fixtures, factories, sample data, and golden data;
- test configuration and dependency files;
- relevant production code, interfaces, schemas, migrations, and documentation;
- commands used by CI and local development.

Search for existing coverage before creating a new test. Extend or parameterize an existing test when that is clearer and avoids duplication.

### 3. Choose the test boundary

Choose the smallest appropriate boundary:

- **Unit:** pure logic and isolated domain rules.
- **Integration:** databases, filesystems, serialization, migrations, queues, containers, and service boundaries.
- **Contract:** API, schema, or external service compatibility.
- **End-to-end:** critical workflows across the real application boundary.

Use integration tests for bugs that unit tests can miss, including SQL behavior, schema mismatches, transactions, null handling, ordering, timezones, filesystem behavior, network boundaries, and concurrency. Do not turn every test into an integration test.

### 4. Design meaningful cases

Use a clear structure:

```text
GIVEN realistic state
WHEN meaningful behavior occurs
THEN observable results and invariants hold
```

Cover relevant variations rather than arbitrary parameter combinations:

- missing values, nulls, and NaNs;
- empty values and empty collections;
- duplicates and idempotent retries;
- malformed or unexpected data;
- boundary values and invalid input;
- out-of-order or late-arriving timestamps;
- extra or missing columns;
- partial records and schema changes;
- invalid encodings;
- meaningful state transitions.

Useful transitions include:

```text
empty → populated
pending → completed
new → duplicate
valid → invalid
unprocessed → processed
version N → version N+1
```

Assert results and domain invariants. Avoid assertions about private state, internal calls, exact implementation structure, or incidental ordering unless those are part of the contract.

### 5. Use data and golden tests carefully

Use small, deterministic, understandable datasets. Golden tests should validate the properties that matter, such as:

- values;
- schema;
- row counts;
- meaningful ordering;
- null distribution;
- relevant metadata.

Avoid large opaque golden files unless they are necessary. Minimize and anonymize production examples whenever possible. Ask the user before using external or sensitive data when approval is required for correctness or privacy.

### 6. Manage infrastructure lifecycle

Every resource created by a test must be disposable and cleaned up even when the test fails:

- containers and background processes;
- databases, schemas, and tables;
- buckets, objects, queues, and Redis keys;
- temporary files and directories;
- environment variables and filesystem state.

Use fixtures, context managers, `try/finally`, or framework-native cleanup. Reuse expensive setup only when mutable state remains isolated.

Typical scope:

```text
container / service      session
model / expensive data   session
database schema          function
transaction              function
temporary files          function
mutable test state       function
```

Never trade isolation for speed.

### 7. Implement and run

After writing the test:

1. Run the narrowest relevant test first.
2. If this is a confirmed unfixed regression, confirm that the test reproduces the bug; otherwise do not manufacture a failure.
3. Run the broader relevant test suite.
4. Distinguish test defects, environment failures, and production defects.
5. Do not weaken an assertion just to make the test pass.
6. Do not fix production code unless explicitly requested.

Control sources of nondeterminism:

- clocks and timezones;
- randomness and UUIDs;
- environment variables;
- network access;
- filesystem locations;
- concurrency timing;
- shared mutable state.

Tests must not depend on execution order, wall-clock timing, or a developer's local machine.

## Mocking Policy

Use real dependencies when their behavior is part of correctness:

```text
real dependency
→ local or official emulator
→ contract-tested stub
→ mock as a last resort
```

Mocks are appropriate for genuinely isolated unit tests, unavailable systems, or interactions whose implementation is not under test. When using a mock for a dependency that could affect correctness, document the concrete reason the real dependency is impractical.

Do not assert only that a mock was called when the actual observable result can be tested.

## Regression Tests

Every confirmed bug should become a regression test unless equivalent coverage already exists:

```text
bug → reproduce → failing test → fix → passing test
```

If the user only requested a test, add the regression test and report whether it passes or correctly exposes the existing defect. Do not silently change production behavior.

## Completion Checklist

Before finishing, verify:

- [ ] The test checks meaningful observable behavior.
- [ ] Existing coverage was searched and duplication was avoided.
- [ ] The chosen test level is appropriate.
- [ ] Important failure modes and state transitions are covered.
- [ ] Domain invariants and contracts are asserted.
- [ ] Real dependencies are used where practical and relevant.
- [ ] Mutable state is isolated.
- [ ] Resources are cleaned up on success and failure.
- [ ] External data or unresolved correctness decisions were requested only when necessary.
- [ ] The test is deterministic and independent of execution order.
- [ ] The narrow and broader relevant test commands were run.
- [ ] Production code was not changed without explicit permission.

## Final Report

Summarize:

- test files added or changed;
- behaviors and failure modes covered;
- commands run and their results;
- infrastructure or external data used;
- any remaining failures, ambiguity, or production defects.
