# Contributing to pgvitals

Thank you for helping make pgvitals better.

## Ways to Contribute

- **New diagnostic section** — a query that catches a real performance issue not yet covered
- **Query improvement** — better accuracy, broader compatibility, or clearer output columns
- **Documentation fix** — typos, clearer thresholds, better action steps
- **Compatibility note** — tested on a specific PostgreSQL version or cloud provider

## New Section Guidelines

Every section must follow this structure:

### File naming

`sql/NN_short_description.sql`

Use the next available two-digit number. If your section fits an existing area (Query, Index, Table, Vacuum, Connections, Replication, Risk, Config), slot it in that range.

### Required header

```sql
-- ============================================================
-- NN · SECTION TITLE IN TITLE CASE
-- ============================================================
-- What    : One sentence — what metric or state this surfaces
-- Look for: Specific threshold or condition that signals a problem
-- Action  : What to do when the threshold is breached
-- Requires: Any extension or privilege beyond pg_monitor (if any)
-- ============================================================
```

### Query standards

- Target PostgreSQL 12+ unless the feature genuinely requires a newer version (note it in the header)
- Use `nullif(x, 0)` instead of bare division to avoid divide-by-zero
- Format sizes with `pg_size_pretty()` for human-readable output
- Include a `LIMIT` clause on any query that could return unbounded rows
- Exclude `pg_catalog` and `information_schema` from user-table queries
- Use explicit column aliases — no bare `*` in final output

### Add to master.sql

After adding your section file, append the same query to `master.sql` with the matching section header comment block.

### Update docs/SECTIONS.md

Add a row to the relevant table in [docs/SECTIONS.md](docs/SECTIONS.md).

---

## Pull Request Process

1. Fork the repo and create a branch: `git checkout -b section/my-new-section`
2. Add your section file, update `master.sql`, and update `docs/SECTIONS.md`
3. Test the query against a real PostgreSQL instance (note the version)
4. Open a PR — describe what the query catches and what threshold you chose

## Reporting Issues

Use the issue templates:

- **Bug report** — query returns wrong results, crashes, or has a compatibility problem
- **Feature request** — a performance area not yet covered

## Code of Conduct

Be constructive and professional. Criticism of queries is welcome; personal attacks are not.
