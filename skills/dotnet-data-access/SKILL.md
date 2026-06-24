---
name: dotnet-data-access
description: >-
  Data-access conventions AND review checks for .NET with Dapper and hand-written
  SQL: parameterization, organising SQL, the repository + unit-of-work pattern,
  connection lifetime, migrations, and real-database integration tests. Use
  whenever building OR reviewing C#/.NET code that reads or writes a database,
  runs SQL, defines or calls a repository, or manages a DB transaction — even if
  the task only mentions "a query", "the database", or a specific table. This is
  the single source of truth both the developer and the reviewers judge against.
---

# Data access (Dapper + hand-written SQL)

- Prefer **Dapper** (`Dapper`, DapperLib) with hand-written SQL as the default
  over EF Core: explicit, predictable queries and full control over the SQL the
  database actually runs. Use EF Core only where a project has already
  standardized on it.
- **Always parameterize.** Never string-concatenate or interpolate user input
  into SQL — pass parameters so the provider handles them. This is the single
  most important rule here, and a security boundary, not just a style choice.
- Keep SQL reviewable: organize queries as named constants or `.sql` resources
  inside the owning repository, not scattered inline. Map results to records/DTOs;
  use multi-mapping and `QueryMultiple` for joins and batched reads.
- Manage `IDbConnection` lifetime through a connection factory in DI; open late,
  dispose promptly, and share a connection/transaction within a unit of work
  (see `dotnet-architecture` for the repository/`IUnitOfWork` shape).
- No EF migrations — pair Dapper with a dedicated migration tool (DbUp,
  FluentMigrator, or versioned SQL scripts) and keep schema changes in source control.
- Verify repositories against a **real** database in integration tests
  (TestContainers); there is no in-memory provider to lean on, and hand-written
  SQL must be exercised against the real engine (see `dotnet-testing`).

## Review checklist

- **Injection** — any user input reaching SQL without parameters? (critical)
- SQL concatenation/interpolation anywhere on an input path.
- Connections/transactions leaked: opened without disposal, or a unit of work
  spanning calls it shouldn't.
- Raw SQL in handlers/services instead of behind a repository.
- N+1 query shapes and over-fetching (cost — coordinate with the performance reviewer).
- Schema change with no corresponding migration script in source control.
- Repository behaviour changed but not covered by a real-DB integration test.