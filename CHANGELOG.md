# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Added
- `37_extension_inventory.sql` — audit installed extensions, detect stale versions and public-schema placement
- `38_foreign_data_wrappers.sql` — enumerate FDW servers, user mappings, and foreign tables
- `39_function_performance.sql` — PL/pgSQL and stored procedure execution stats (requires `track_functions`)
- `40_schema_size_breakdown.sql` — storage by schema with table / index / TOAST breakdown
- Dynamic CI section-count check: validates contiguous file numbering instead of a hardcoded count
- `ROADMAP.md` — phased plan for upcoming work
- Multi-version CI matrix: every section is executed against PostgreSQL 13–17 on each push
- `-- Min-PG:` machine-readable version-gate header on version-specific sections (05, 33, 36)
- README "Safety — Read-Only by Design" section documenting the CI-enforced read-only guarantee

### Changed
- Documented core-compatibility floor corrected to PostgreSQL 13 (was 12); `pg_stat_statements`
  renamed `total_time` → `total_exec_time` in PG 13, which sections 01/02/04/05 rely on

### Fixed
- `05_jit_overhead.sql` required version corrected to PG 15+ (JIT counters were added to
  `pg_stat_statements` in PG 15, not 11)
- README compatibility table: WAL generation (§33) and `pg_stat_io` (§36) version requirements
- README documented previously-missing sections 37–40

---

## [1.1.0] — 2026-06

### Added
- `33_wal_generation.sql` — WAL generation volume and rate since stats reset (PostgreSQL 14+)
- `34_partitioned_table_health.sql` — partition counts and sizes per partitioned table
- `35_prepared_transactions.sql` — open two-phase commit transactions that block vacuum
- `36_pg_stat_io.sql` — I/O statistics broken down by backend type and context (PostgreSQL 16+)
- OG image for social sharing (`docs/og-image.svg`)
- Runbook cross-references in the diagnostic web UI (`docs/runbooks.js`)

### Improved
- 13 existing queries updated for correctness and PostgreSQL 17 compatibility
- CI now validates monitoring schema (`monitoring/schema.sql`, `capture_snapshot.sql`)
- CI uses `ON_ERROR_STOP=on` and GitHub Actions error annotations

---

## [1.0.0] — Initial release

### Added
- 32 copy-paste PostgreSQL diagnostic queries (sections 00–32) covering:
  - Query behaviour: slow queries, temp spill, seq scan storms, N+1, JIT overhead
  - Index health: unused, duplicate, invalid, missing FK indexes, bloat
  - Tables & storage: table bloat, TOAST bloat, size ranking, access patterns
  - Vacuum & statistics: autovacuum progress, dead tuple backlog, stale stats
  - Connections & locks: saturation, idle-in-transaction, lock trees, wait events
  - Replication: streaming lag, logical slot lag, WAL retention
  - Risk signals: XID/MXID wraparound, sequence exhaustion
  - Config & health: GUC review, buffer cache, checkpoint pressure, DB summary
- `master.sql` — single combined file for full diagnostic sweeps
- Monitoring framework (`monitoring/`) — snapshot schema, capture function, trend queries
- GitHub Actions CI — header validation, DML/DDL guard, SQL syntax check against PostgreSQL 16
