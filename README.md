# pgvitals

> A comprehensive collection of PostgreSQL performance diagnostic queries covering every common bottleneck — from slow queries and index health to wraparound risk and replication lag.

Designed for two workflows:
- **Ad-hoc investigation** — open any section file, run the query, act on the result
- **Load test monitoring** — use the snapshot framework to capture metrics at intervals and diff them over time

---

## Prerequisites

```sql
-- Must be in postgresql.conf (restart required)
shared_preload_libraries = 'pg_stat_statements'

-- Run once per database
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Recommended role
GRANT pg_monitor TO your_user;
```

---

## Quick Start — Ad-hoc

```bash
# Run a single section
psql -d mydb -f sql/01_slow_queries.sql

# Run all sections in order
for f in sql/*.sql; do psql -d mydb -f "$f"; done
```

---

## Load Test Monitoring

### 1. Setup (run once)

```sql
\i monitoring/schema.sql          -- creates perf_monitor schema + tables
\i monitoring/capture_snapshot.sql -- installs capture_snapshot() function
```

### 2. Capture baseline before the test

```sql
SELECT perf_monitor.capture_snapshot('baseline', 'before any load');
```

### 3. Run your load test (k6, pgbench, JMeter, Locust...)

### 4. Capture snapshots at intervals

Option A — manual milestones:
```sql
SELECT perf_monitor.capture_snapshot('ramp_up');
SELECT perf_monitor.capture_snapshot('peak');
SELECT perf_monitor.capture_snapshot('cooldown');
```

Option B — automated every 30 seconds via psql `\watch`:
```sql
\t on
SELECT perf_monitor.capture_snapshot('load_test'); \watch 30
```

Option C — shell loop:
```bash
while true; do
  psql -d mydb -c "SELECT perf_monitor.capture_snapshot('load_test');"
  sleep 60
done
```

### 5. Analyse results

```sql
\i monitoring/trend_queries.sql
```

### 6. Teardown

```sql
DROP SCHEMA perf_monitor CASCADE;
```

---

## Section Index

| Area | # | Section | Key threshold |
|------|---|---------|---------------|
| Query | 01 | Slow / expensive queries | `mean_exec_ms > 100` |
| Query | 02 | Temp file & work_mem pressure | Any `temp_written_mb > 0` |
| Query | 03 | Sequential scan hotspots | `seq_scan_pct > 50%` on large tables |
| Query | 04 | N+1 patterns | `calls > 10000` |
| Query | 05 | JIT compilation overhead | `total_jit_ms > mean_exec_ms` |
| Index | 06 | Unused indexes | `idx_scan = 0` |
| Index | 07 | Duplicate / redundant indexes | Any row |
| Index | 08 | Invalid indexes | Any row |
| Index | 09 | Missing FK indexes | Any row |
| Index | 10 | Index bloat | `bloat_pct > 30%` |
| Table | 11 | Table bloat | `bloat_pct > 20%` |
| Table | 12 | TOAST table bloat | `toast_to_table_pct > 200%` |
| Table | 13 | Table & index size ranking | Unexpected growth |
| Table | 14 | Table access patterns | `dead_pct > 10%` |
| Vacuum | 15 | Autovacuum worker activity | Stuck workers |
| Vacuum | 16 | Dead tuple urgency | `dead_pct > 10%` |
| Vacuum | 17 | Stale statistics | `mod_pct > 10%` |
| Vacuum | 18 | Long-running transactions | `xact_duration > 5min` |
| Conn | 19 | Connection saturation | `used_pct > 80%` |
| Conn | 20 | Idle-in-transaction | `idle_duration > 30s` |
| Conn | 21 | Lock wait tree | Any row |
| Conn | 22 | Wait events breakdown | `sessions > 5` |
| Repl | 23 | Streaming replication lag | `replay_lag > 30s` |
| Repl | 24 | Logical replication slot lag | Lag > 500 MB |
| Repl | 25 | Replication slot WAL retention | Approaching disk limit |
| Risk | 26 | XID wraparound risk | `pct_used > 70%` |
| Risk | 27 | MultiXact wraparound risk | `pct_used > 70%` |
| Risk | 28 | Sequence exhaustion | `pct_used > 80%` |
| Config | 29 | Key GUC settings review | `source = 'default'` on memory |
| Config | 30 | Buffer cache hit ratio | `hit_ratio_pct < 95%` |
| Config | 31 | Checkpoint / WAL pressure | `forced_pct > 10%` |
| Config | 32 | Database-level summary | `rollback_pct > 5%`, `deadlocks > 0` |

Full details with thresholds and recommended actions: [docs/SECTIONS.md](docs/SECTIONS.md)

---

## Repository Layout

```
pgvitals/
├── sql/                    32 individual diagnostic queries
│   ├── 00_prerequisites.sql
│   ├── 01_slow_queries.sql
│   └── ...
├── monitoring/             Load test snapshot framework
│   ├── schema.sql          perf_monitor schema + tables
│   ├── capture_snapshot.sql  capture_snapshot() function
│   └── trend_queries.sql   delta and trend analysis
├── docs/
│   └── SECTIONS.md         Quick reference table
└── master.sql              All sections combined in one file
```

---

## Compatibility

- PostgreSQL **14+** (JIT stats require 14+; most queries work on 12+)
- No extensions required beyond `pg_stat_statements`
- Optional: `pgstattuple` for precise bloat figures (sections 10, 11)

---

## Contributing

Issues and PRs welcome. When adding a new section please follow the existing header format:

```sql
-- ============================================================
-- NN · SECTION TITLE
-- ============================================================
-- What    : one line description
-- Look for: threshold that indicates a problem
-- Action  : what to do when you see the threshold breached
-- ============================================================
```

---

## License

MIT
