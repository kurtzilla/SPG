---
description: Do not create or modify unit tests unless the user explicitly requests tests
alwaysApply: true
---

# No unit tests (default)

SPG has **no unit test suite**. Do not add one opportunistically.

## Forbidden without explicit user request

- Files under `tests/`, `**/*Tests*.cs`, `**/*.Tests.csproj`
- xUnit, NUnit, MSTest, `Microsoft.NET.Test.Sdk`, test runners
- Rewriting or "migrating" tests when refactoring production code
- Plan todos or PR steps that include test work
- `dotnet test` or suggesting the user run tests

## Allowed

- Manual / in-editor verification (Godot play, visual check)
- Stating that behavior should be verified manually

## When the user explicitly asks for tests

Only then: create or change test projects and test code, scoped to what they asked for.
