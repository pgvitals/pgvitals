<div align="center">

# 🩺 pgvitals

**40 copy-paste PostgreSQL diagnostic queries — one for every performance bottleneck.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-13%E2%80%9317-blue?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Validate](https://github.com/pgvitals/pgvitals/actions/workflows/validate.yml/badge.svg)](https://github.com/pgvitals/pgvitals/actions/workflows/validate.yml)
[![Docker](https://img.shields.io/badge/ghcr.io-pgvitals-2496ED?logo=docker&logoColor=white)](https://github.com/pgvitals/pgvitals/pkgs/container/pgvitals)
[![PyPI](https://img.shields.io/pypi/v/pgvitals?color=blue)](https://pypi.org/project/pgvitals/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

*No extensions. No installation. Just SQL.*

</div>

---

When PostgreSQL is slow, the answer is always in the catalog — if you know where to look.

**pgvitals** is a curated, production-tested collection of diagnostic queries that cover every common performance bottleneck: slow queries, index health, table bloat, vacuum lag, connection exhaustion, lock contention, replication lag, wraparound risk, and more. Each query comes with a header that tells you exactly what to look for and what to do about it.

Run a single section during an incident. Run all of them before a release. Wire up the snapshot framework to collect metrics during a load test.

---

## Quickstart

```bash
# Single section — e.g. what's blocking right now
psql -d mydb -f sql/21_lock_wait_tree.sql

# Full diagnostic sweep
for f in sql/*.sql; do echo "=== $f ==="; psql -d mydb -f "$f"; done

# Or load the combined master file
psql -d mydb -f master.sql

# Health score — 0-100 with per-check breakdown (no extensions needed)
psql -d mydb -f health_score.sql
```

### Or install the CLI

```bash
pip install pgvitals
pgvitals init                                         # download SQL files
pgvitals --host db.example.com --database prod        # full diagnostic run
```

**Prerequisites** (one-time setup):

```sql
-- postgresql.conf (requires restart)
shared_preload_libraries = 'pg_stat_statements'

-- per database
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
GRANT pg_monitor TO your_user;   -- PostgreSQL 10+
```

---

## Coverage

| Area | Sections | What gets caught |
|------|----------|-----------------|
| **Query behavior** | 01–05 | Slow queries · temp spill · seq scan storms · N+1 · JIT overhead |
| **Index health** | 06–10 | Unused · duplicate · invalid · missing FK indexes · bloat |
| **Tables & storage** | 11–14, 34 | Table bloat · TOAST bloat · size ranking · access patterns · partition health |
| **Vacuum & stats** | 15–18 | Autovacuum progress · dead tuple backlog · stale stats · blocking txns |
| **Connections & locks** | 19–22 | Connection saturation · idle-in-txn · lock trees · wait events |
| **Replication** | 23–25 | Streaming lag · logical slot lag · WAL retention |
| **Risk signals** | 26–28, 35 | XID wraparound · MultiXact wraparound · sequence exhaustion · prepared transactions |
| **Config & health** | 29–32, 33, 36 | GUC review · buffer cache · checkpoint pressure · DB summary · WAL rate · I/O stats |
| **Extensions & schema** | 37–40 | Installed extensions · foreign data wrappers · function performance · schema size breakdown |

---

## Each Query Tells You What to Do

Every section follows the same four-line header:

```sql
-- ============================================================
-- 21 · LOCK WAIT TREE (BLOCKING CHAINS)
-- ============================================================
-- What    : Full chain of who is blocking whom
-- Look for: Any row — every lock wait degrades throughput
-- Action  : Find root blocker (blocking_pids = '{}') and
--           investigate or terminate: pg_terminate_backend(pid)
-- ============================================================
```

No hunting through docs. The threshold and next step are right there.

---

## Load Test Monitoring

For stress testing, pgvitals includes a snapshot framework that records metrics over time so you can diff baseline vs peak.

### Setup

```sql
\i monitoring/schema.sql           -- creates perf_monitor schema
\i monitoring/capture_snapshot.sql -- installs capture_snapshot()
```

### Workflow

```sql
-- Before your load test
SELECT perf_monitor.capture_snapshot('baseline');

-- During the test — or automate with \watch
SELECT perf_monitor.capture_snapshot('peak'); \watch 30

-- After the test
SELECT perf_monitor.capture_snapshot('cooldown');
```

### Analyse

```sql
\i monitoring/trend_queries.sql
```

Queries included: connection saturation over time · lock wait spikes · dead tuple growth · cache hit ratio trend · deadlock count · checkpoint pressure · temp file spill · rollback rate.

### Teardown

```sql
DROP SCHEMA perf_monitor CASCADE;
```

---

## Diagnostic Runner

pgvitals includes a Python-based runner that executes all sections against a live database and generates a Markdown health report.

### Via pip (recommended)

```bash
pip install pgvitals
pgvitals init                                               # download SQL files once
pgvitals --host db.example.com --user dba --database prod  # full diagnostic run
pgvitals --profile staging                                  # use a named config profile
pgvitals --sections 01,03,19,26,32                         # run specific sections only
pgvitals --skip 05,36                                       # skip specific sections
pgvitals --output ./report.md                               # custom output path
pgvitals --format html -o report.html                       # self-contained shareable HTML report
```

### Via script (no install)

```bash
cd runner

# Copy sample config and edit your connection details
cp pgvitals.conf.example pgvitals.conf

# Run all diagnostics
python run_diagnostics.py

# Use a named profile
python run_diagnostics.py --profile staging

# Override connection via CLI
python run_diagnostics.py --host db.example.com -U monitor -d production
```

### Via Docker (no install)

The image bundles the SQL sections and `psql` — nothing to install but Docker:

```bash
# Full diagnostic run
docker run --rm -e PGPASSWORD=secret ghcr.io/pgvitals/pgvitals \
  --host db.example.com --user dba --database prod

# Save a self-contained HTML report to the current directory
docker run --rm -e PGPASSWORD=secret -v "$PWD:/out" ghcr.io/pgvitals/pgvitals \
  --host db.example.com --user dba --database prod \
  --format html --output /out/report.html
```

### Configuration

The runner uses a layered config system (lowest → highest priority):

1. `pgvitals.conf` (or `--config <path>`)
2. Named profiles (`--profile staging`)
3. Environment variables (`PGPASSWORD`, `PGHOST`, etc.)
4. CLI arguments (`--host`, `--user`, `--database`)

See [`pgvitals.conf.example`](runner/pgvitals.conf.example) for all available options.

### Report Output

Reports are written to `runner/reports/` with auto-generated filenames and include:

- Executive summary table with status badges
- Health score breakdown by area
- Detailed output for every section
- Prioritized recommendations (critical → medium → info)

Pass `--format html` for a **self-contained, shareable HTML report** — a single file (inline CSS/JS, no external assets, works from `file://`) with a 0–100 health-score gauge, color-coded collapsible section cards, and a one-click *Print / Save PDF* button. Markdown remains the default.

### Output formats

| `--format` | Output | Use it for |
|------------|--------|------------|
| `markdown` *(default)* | `.md` | Human-readable report, PR comments |
| `html` | `.html` | Self-contained shareable report with score gauge |
| `json` | `.json` | Piping into other tools, dashboards, diffing, automation |
| `prometheus` | `.prom` | Scraping into Prometheus / Grafana + alerting |

**`--format json`** emits a stable, machine-readable document (`schema_version` `1.0`) with the score/grade, per-area rollups, and one object per section (`num`, `area`, `risk`, `status`, `rows`, header, raw output):

```bash
pgvitals --host db.example.com --database prod --format json -o pgvitals.json
jq '.score, (.sections[] | select(.status=="findings" and .risk=="critical").title)' pgvitals.json
```

**`--format prometheus`** turns a one-shot run into a scrapeable, alertable signal in the
text exposition format — ideal for the node_exporter **textfile collector**:

```bash
pgvitals --host db.example.com --database prod \
  --format prometheus -o /var/lib/node_exporter/textfile_collector/pgvitals.prom
```

Key series (every metric is labeled by `database`; sections also carry `area`, `risk`, `title`):

```
pgvitals_health_score{database="prod"}                     82
pgvitals_section_findings{database="prod",section="26",risk="critical",...}  1
pgvitals_section_up{database="prod",section="36"}           0     # errored / unavailable
pgvitals_sections{database="prod",status="findings"}        7
```

Because `risk` is a label, alerting is one expression — e.g. page on any critical finding:

```promql
max(pgvitals_section_findings{risk="critical"}) > 0
```

### AI analysis (`--explain`)

Add `--explain` to get a prioritized, plain-English analysis of the findings — *"what's wrong → fix in this order"*, with the exact SQL/commands — generated by Claude and embedded at the top of the report (both Markdown and HTML).

```bash
export ANTHROPIC_API_KEY=sk-ant-...
pgvitals --host db.example.com --database prod --explain --format html -o report.html
pgvitals --host db.example.com --database prod --explain --explain-model claude-opus-4-8
```

- Uses the Anthropic API directly over `urllib` — **no extra dependencies** to install.
- Default model: `claude-sonnet-4-6` (override with `--explain-model`).
- **Privacy**: `--explain` sends the diagnostic findings (section titles, suggested actions, truncated query output, and the database name) to Anthropic. It is strictly opt-in and does nothing unless `ANTHROPIC_API_KEY` is set — a run without the flag never leaves your machine. If the key is missing or the API call fails, the diagnostic report is still produced as normal.

> **Note**: `runner/pgvitals.conf` is gitignored to protect credentials. Never commit database passwords.

### Requirements

- Python 3.8+ (no third-party dependencies)
- `psql` on PATH or configured in `pgvitals.conf`


## Section Reference

<details>
<summary><b>Query Behavior (01–05)</b></summary>

| # | File | What it catches | Threshold |
|---|------|-----------------|-----------|
| 01 | `sql/01_slow_queries.sql` | Top queries by total CPU time | `mean_exec_ms > 100` |
| 02 | `sql/02_temp_pressure.sql` | Queries spilling to disk | Any `temp_written_mb > 0` |
| 03 | `sql/03_seq_scan_hotspots.sql` | Tables hit with full seq scans | `seq_scan_pct > 50%` on large tables |
| 04 | `sql/04_n_plus_one.sql` | ORM N+1 / chatty query patterns | `calls > 10,000` |
| 05 | `sql/05_jit_overhead.sql` | JIT cost exceeding its benefit | `total_jit_ms > mean_exec_ms` |

</details>

<details>
<summary><b>Index Health (06–10)</b></summary>

| # | File | What it catches | Threshold |
|---|------|-----------------|-----------|
| 06 | `sql/06_unused_indexes.sql` | Write-only indexes wasting space | `idx_scan = 0` |
| 07 | `sql/07_duplicate_indexes.sql` | Redundant overlapping indexes | Any row |
| 08 | `sql/08_invalid_indexes.sql` | Failed `CREATE CONCURRENTLY` leftovers | Any row |
| 09 | `sql/09_missing_fk_indexes.sql` | FK columns without a supporting index | Any row |
| 10 | `sql/10_index_bloat.sql` | Fragmented index pages | `bloat_pct > 30%` |

</details>

<details>
<summary><b>Tables & Storage (11–14, 34)</b></summary>

| # | File | What it catches | Threshold |
|---|------|-----------------|-----------|
| 11 | `sql/11_table_bloat.sql` | Dead space in the heap | `bloat_pct > 20%` |
| 12 | `sql/12_toast_bloat.sql` | Oversized TOAST tables | `toast_to_table_pct > 200%` |
| 13 | `sql/13_table_size_ranking.sql` | Top space consumers | Unexpected growth |
| 14 | `sql/14_table_access_patterns.sql` | Heap vs index fetch ratio | `dead_pct > 10%` |
| 34 | `sql/34_partitioned_table_health.sql` | Partition count and sizes | `partition_count > 100` |

</details>

<details>
<summary><b>Vacuum & Statistics (15–18)</b></summary>

| # | File | What it catches | Threshold |
|---|------|-----------------|-----------|
| 15 | `sql/15_autovacuum_activity.sql` | Live vacuum worker progress | Stuck workers |
| 16 | `sql/16_dead_tuple_urgency.sql` | Tables with vacuum backlog | `dead_pct > 10%` |
| 17 | `sql/17_stale_statistics.sql` | Tables where planner stats are stale | `mod_pct > 10%` |
| 18 | `sql/18_long_running_transactions.sql` | Transactions blocking vacuum | `xact_duration > 5 min` |

</details>

<details>
<summary><b>Connections & Locks (19–22)</b></summary>

| # | File | What it catches | Threshold |
|---|------|-----------------|-----------|
| 19 | `sql/19_connection_saturation.sql` | `max_connections` headroom | `used_pct > 80%` |
| 20 | `sql/20_idle_in_transaction.sql` | Silent lock holders | `idle_duration > 30s` |
| 21 | `sql/21_lock_wait_tree.sql` | Full blocking chain | Any row |
| 22 | `sql/22_wait_events.sql` | What sessions are currently waiting on | `sessions > 5` |

</details>

<details>
<summary><b>Replication (23–25)</b></summary>

| # | File | What it catches | Threshold |
|---|------|-----------------|-----------|
| 23 | `sql/23_streaming_replication_lag.sql` | Per-standby write/flush/replay lag | `replay_lag > 30s` |
| 24 | `sql/24_logical_replication_lag.sql` | Logical consumer lag | Lag > 500 MB |
| 25 | `sql/25_replication_slot_wal.sql` | WAL retained by all slots | Approaching disk limit |

</details>

<details>
<summary><b>Critical Risk Signals (26–28, 35)</b></summary>

| # | File | What it catches | Threshold |
|---|------|-----------------|-----------|
| 26 | `sql/26_xid_wraparound.sql` | Transaction ID exhaustion | `pct_used > 70%` |
| 27 | `sql/27_mxid_wraparound.sql` | MultiXact ID exhaustion | `pct_used > 70%` |
| 28 | `sql/28_sequence_exhaustion.sql` | Sequences approaching integer overflow | `pct_used > 80%` |
| 35 | `sql/35_prepared_transactions.sql` | Two-phase commit transaction leaks | Any row > 5 minutes |

</details>

<details>
<summary><b>Config & Health (29–32, 33, 36)</b></summary>

| # | File | What it catches | Threshold |
|---|------|-----------------|-----------|
| 29 | `sql/29_guc_settings.sql` | Key config params vs recommended values | `source = 'default'` on memory |
| 30 | `sql/30_buffer_cache_hit.sql` | Cache hit ratio per table and globally | `hit_ratio_pct < 95%` |
| 31 | `sql/31_checkpoint_pressure.sql` | Forced checkpoints and backend fsync | `forced_pct > 10%`, `backend_fsync > 0` |
| 32 | `sql/32_database_summary.sql` | DB-level rollbacks, deadlocks, temp usage | `rollback_pct > 5%`, `deadlocks > 0` |
| 33 | `sql/33_wal_generation.sql` | WAL generation volume and rate | `wal_mb_per_hour > 1000` |
| 36 | `sql/36_pg_stat_io.sql` | I/O statistics by backend type | Evictions / Temp I/O spike |

</details>

<details>
<summary><b>Extensions & Schema (37–40)</b></summary>

| # | File | What it catches | Threshold |
|---|------|-----------------|-----------|
| 37 | `sql/37_extension_inventory.sql` | Stale extensions, ones in `public` schema | `installed_version != default_version` |
| 38 | `sql/38_foreign_data_wrappers.sql` | FDW servers, user mappings, foreign tables | Unrecognised remotes / broken mappings |
| 39 | `sql/39_function_performance.sql` | Slow PL/pgSQL functions & procedures | High `self_time` ratio (needs `track_functions`) |
| 40 | `sql/40_schema_size_breakdown.sql` | Storage consumed per schema | Unexpected schema growth |

</details>

---

## Health Score

Get a single 0–100 score for your database with a per-check breakdown — no extensions, no config, just SQL:

```bash
psql -d mydb -f health_score.sql
```

```
╔════════════════════════╤═════════╤══════════════════════════════╤══════════╤══════════╤══════════╗
║ Score                  │ Grade   │ Status                       │ ✓ Passed │ ~ Warned │ ✗ Failed ║
╠════════════════════════╪═════════╪══════════════════════════════╪══════════╪══════════╪══════════╣
║ 87 / 100               │ B       │ Good — minor issues to review│        8 │        1 │        0 ║
╚════════════════════════╧═════════╧══════════════════════════════╧══════════╧══════════╧══════════╝

╔═══╤══════════════════════════╤═══════════╤═══════════╤════════════════════════════════════════╗
║ # │ Check                    │ Score     │ Status    │ Detail                                 ║
╠═══╪══════════════════════════╪═══════════╪═══════════╪════════════════════════════════════════╣
║ 1 │ XID Wraparound           │ 20 / 20   │ ✓ Clear   │ max age: 2,933 txns (limit ~2 billion) ║
║ 2 │ Dead Tuple Bloat         │ 15 / 15   │ ✓ Clear   │ 0 table(s) with >10% dead tuples       ║
║ 3 │ Connection Saturation    │ 15 / 15   │ ✓ Clear   │ 63.0% of max_connections in use        ║
║ 4 │ Lock Waits               │ 10 / 10   │ ✓ Clear   │ 0 session(s) currently blocked         ║
║ 5 │ Buffer Cache Hit Ratio   │  5 / 10   │ ~ Warning │ 93.20% hit rate (target ≥ 95%)         ║
║ 6 │ Invalid Indexes          │ 10 / 10   │ ✓ Clear   │ 0 invalid index(es) detected           ║
║ 7 │ Idle-in-Transaction      │ 10 / 10   │ ✓ Clear   │ 0 session(s) stuck in open transaction ║
║ 8 │ Replication Lag          │  5 /  5   │ ✓ Clear   │ 0 standby(s) configured                ║
║ 9 │ Sequence Exhaustion      │  5 /  5   │ ✓ Clear   │ 0 sequence(s) above 80% capacity       ║
╚═══╧══════════════════════════╧═══════════╧═══════════╧════════════════════════════════════════╝
```

---

## GitHub Actions Integration

Add a scheduled health check to any repo — copies the workflow template and wires up your DB secrets:

```bash
# Copy the template to your repo
cp .github/workflows/pgvitals-healthcheck.yml path/to/your-repo/.github/workflows/

# Set these secrets in Settings → Secrets → Actions:
#   PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
```

The health score runs on every push and on a weekly schedule. Results appear in the Actions job summary. The job fails if the grade drops to D or F.

See the full template: [`.github/workflows/pgvitals-healthcheck.yml`](.github/workflows/pgvitals-healthcheck.yml)

### As a reusable Action

Prefer a one-liner over copying a template? Use the composite action directly — it runs the health score, posts it to the job summary, exposes `score`/`grade` outputs, and fails the job below a threshold:

```yaml
- name: PostgreSQL health check
  uses: pgvitals/pgvitals@v1
  with:
    host: ${{ secrets.PGHOST }}
    database: ${{ secrets.PGDATABASE }}
    user: ${{ secrets.PGUSER }}
    password: ${{ secrets.PGPASSWORD }}
    fail-under: '60'      # fail the job if score < 60 (set 0 to never fail)
```

Inputs: `host` (required), `database` (required), `user` (required), `password`, `port` (default `5432`), `sslmode` (default `prefer`), `fail-under` (default `60`). Outputs: `score`, `grade`.

### Health badge

The workflow also generates a self-contained SVG badge (e.g. `postgres health: B · 87`), coloured by grade — no shields.io or third-party service. It's uploaded as a build artifact; to show it in your README, uncomment the *Publish badge to `badges` branch* step in the template and embed:

```markdown
![pgvitals](https://raw.githubusercontent.com/<owner>/<repo>/badges/pgvitals-badge.svg)
```

Generate one locally too: `python runner/make_badge.py --score 87 --grade B --out badge.svg`

---

## Repository Layout

```
pgvitals/
├── sql/                        40 individual diagnostic queries
│   ├── 00_prerequisites.sql
│   ├── 01_slow_queries.sql
│   └── ...
├── health_score.sql            0-100 health score (standalone)
├── monitoring/                 Load test snapshot framework
│   ├── schema.sql
│   ├── capture_snapshot.sql
│   └── trend_queries.sql
├── runner/                     Diagnostic runner & report generator
│   ├── run_diagnostics.py      Main runner script (Python 3.8+)
│   ├── pgvitals.conf.example
│   └── reports/
├── pgvitals/                   pip-installable package
│   ├── __init__.py
│   └── cli.py
├── pyproject.toml              pip package config
├── docs/
│   └── SECTIONS.md
├── master.sql
└── README.md
```

---

## Compatibility

| Feature | Requirement |
|---------|-------------|
| Core queries | PostgreSQL 13+ (`pg_stat_statements` renamed `total_time` → `total_exec_time` in PG 13) |
| JIT stats (section 05) | PostgreSQL 15+ (JIT counters added to `pg_stat_statements` in PG 15) |
| WAL generation (section 33) | PostgreSQL 14+ (`pg_stat_wal`) |
| I/O statistics (section 36) | PostgreSQL 16+ (`pg_stat_io`) |
| `pg_stat_statements` | Required (in `shared_preload_libraries`) |
| `pgstattuple` | Optional — enables precise bloat figures |
| Privileges | `pg_monitor` role or superuser |

---

## Safety — Read-Only by Design

Every query in `sql/` (and `master.sql`, `health_score.sql`) is **read-only**: plain
`SELECT`s against system catalogs and statistics views. There is no
`INSERT`/`UPDATE`/`DELETE`/DDL, no table locks beyond the momentary `AccessShareLock`
any `SELECT` takes, and nothing that blocks your workload — safe to run on production
during an incident.

This is **enforced in CI**, not just promised:

- The build fails if any section file contains a DML/DDL keyword.
- Every section is executed against **PostgreSQL 13 – 17** on each push (version-gated
  sections are skipped only where the underlying view doesn't exist yet).

The only components that write are opt-in and clearly separated: `monitoring/` creates a
dedicated `perf_monitor` schema for load-test snapshots, which you install explicitly and
remove with `DROP SCHEMA perf_monitor CASCADE`.

---

## Why pgvitals?

Most diagnostic tools require installation, a running agent, or a specific language runtime. pgvitals is just SQL — it works anywhere `psql` works, requires no dependencies beyond `pg_stat_statements`, and every query is readable and auditable.

| | pgvitals | pgBadger | pganalyze | pg_activity |
|---|---|---|---|---|
| Zero install | ✅ | ❌ (Perl) | ❌ (SaaS) | ❌ (Python) |
| Works on any server | ✅ | Log access needed | Agent needed | Local only |
| Load test snapshots | ✅ | ❌ | ✅ | ❌ |
| Copy-paste ready | ✅ | ❌ | ❌ | ❌ |
| Health score (0-100) | ✅ | ❌ | ✅ | ❌ |
| GitHub Actions ready | ✅ | ❌ | ❌ | ❌ |
| pip installable | ✅ | ❌ | ❌ | ✅ |
| Open source | ✅ | ✅ | ❌ | ✅ |

---

## Contributing

Contributions are welcome — new sections, improved queries, fixes, and documentation improvements.

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR. Every new section should follow the standard header format so the collection stays consistent.

---

## License

MIT — see [LICENSE](LICENSE).
