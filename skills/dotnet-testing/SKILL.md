---
name: dotnet-testing
description: >-
  Testing conventions AND review checks for .NET: the test stack (xUnit v3,
  NSubstitute/FakeItEasy, Bogus, WebApplicationFactory, TestContainers), the
  red→green→refactor TDD loop, and coverage philosophy. Use whenever writing or
  reviewing tests, deciding how to test a change, judging whether new behaviour
  is meaningfully covered, or running the TDD loop — even if the task just says
  "add tests" or "is this tested?".
---

# Testing

- **xUnit v3** (or TUnit) on the Microsoft Testing Platform; xUnit v2 is
  maintenance-only.
- **Mocking**: NSubstitute or FakeItEasy (both MIT, no telemetry). Avoid Moq by
  default given the 2023 SponsorLink incident, unless the project already uses it.
- **Fake data**: Bogus. AutoFixture only if already adopted (limited maintenance;
  v5 still in preview).
- `WebApplicationFactory<T>` for in-process API tests; **TestContainers** for real
  databases and brokers in integration tests (hand-written Dapper SQL must be
  exercised against the real engine — see `dotnet-data-access`).
- **Coverage is a diagnostic, not a target.** Chase meaningful behavioural
  coverage, not a percentage — never write low-value tests to hit a number.
- **Naming** should follow the Given When Then format.

## TDD loop (red → green → refactor)

1. **Red** — write one failing test for the next small behaviour. Run
   `dotnet test`; confirm it fails for the right reason.
2. **Green** — write the minimum code to pass. Run `dotnet test`; confirm green.
3. **Refactor** — remove duplication and improve names with tests green; re-run.
4. Repeat in small increments. Test behaviour, not implementation; use AAA and
   descriptive test names.

## Review checklist

- New behaviour, edge cases, and failure modes meaningfully covered (flag notably
  untested changed code — don't chase a percentage).
- Tests assert **behaviour, not implementation**; isolated; no shared mutable state.
- Repository / SQL changes covered by a real-DB integration test, not mocks.
- No tests written purely to hit a coverage number.