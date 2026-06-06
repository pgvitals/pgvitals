# pgvitals — Section Reference

Quick reference for all 32 diagnostic sections.

## Query Behavior

| # | File | What it catches | Key threshold |
|---|------|-----------------|---------------|
| 01 | `sql/01_slow_queries.sql` | Top queries by total CPU time | `mean_exec_ms > 100` |
| 02 | `sql/02_temp_pressure.sql` | Queries spilling to disk | Any `temp_written_mb > 0` |
| 03 | `sql/03_seq_scan_hotspots.sql` | Missing index signals | `seq_scan_pct > 50%` on large tables |
| 04 | `sql/04_n_plus_one.sql` | ORM N+1 / chatty query patterns | `calls > 10000` |
| 05 | `sql/05_jit_overhead.sql` | JIT cost vs benefit | `total_jit_ms > mean_exec_ms` |

## Index Health

| # | File | What it catches | Key threshold |
|---|------|-----------------|---------------|
| 06 | `sql/06_unused_indexes.sql` | Write-only indexes | `idx_scan = 0` |
| 07 | `sql/07_duplicate_indexes.sql` | Redundant index pairs | Any row |
| 08 | `sql/08_invalid_indexes.sql` | Failed CONCURRENTLY builds | Any row |
| 09 | `sql/09_missing_fk_indexes.sql` | Unindexed FK columns | Any row |
| 10 | `sql/10_index_bloat.sql` | Fragmented index pages | `bloat_pct > 30%` |

## Tables & Storage

| # | File | What it catches | Key threshold |
|---|------|-----------------|---------------|
| 11 | `sql/11_table_bloat.sql` | Dead space in heap | `bloat_pct > 20%` |
| 12 | `sql/12_toast_bloat.sql` | Oversized TOAST tables | `toast_to_table_pct > 200%` |
| 13 | `sql/13_table_size_ranking.sql` | Top space consumers | Unexpected growth |
| 14 | `sql/14_table_access_patterns.sql` | Heap vs index fetch ratio | `dead_pct > 10%` |

## Vacuum & Statistics

| # | File | What it catches | Key threshold |
|---|------|-----------------|---------------|
| 15 | `sql/15_autovacuum_activity.sql` | Live vacuum worker progress | Stuck workers |
| 16 | `sql/16_dead_tuple_urgency.sql` | Vacuum backlog | `dead_pct > 10%` |
| 17 | `sql/17_stale_statistics.sql` | Planner using stale stats | `mod_pct > 10%` |
| 18 | `sql/18_long_running_transactions.sql` | Transactions blocking vacuum | `xact_duration > 5min` |

## Connections & Locks

| # | File | What it catches | Key threshold |
|---|------|-----------------|---------------|
| 19 | `sql/19_connection_saturation.sql` | Max connections headroom | `used_pct > 80%` |
| 20 | `sql/20_idle_in_transaction.sql` | Silent lock holders | `idle_duration > 30s` |
| 21 | `sql/21_lock_wait_tree.sql` | Full blocking chain | Any row |
| 22 | `sql/22_wait_events.sql` | What sessions wait on | `sessions > 5` |

## Replication

| # | File | What it catches | Key threshold |
|---|------|-----------------|---------------|
| 23 | `sql/23_streaming_replication_lag.sql` | Per-standby replay lag | `replay_lag > 30s` |
| 24 | `sql/24_logical_replication_lag.sql` | Logical consumer lag | `lag > 500 MB` |
| 25 | `sql/25_replication_slot_wal.sql` | WAL retained by all slots | Approaching disk limit |

## Critical Risk Signals

| # | File | What it catches | Key threshold |
|---|------|-----------------|---------------|
| 26 | `sql/26_xid_wraparound.sql` | XID exhaustion | `pct_used > 70%` |
| 27 | `sql/27_mxid_wraparound.sql` | MultiXact exhaustion | `pct_used > 70%` |
| 28 | `sql/28_sequence_exhaustion.sql` | Integer overflow risk | `pct_used > 80%` |

## Config & Health

| # | File | What it catches | Key threshold |
|---|------|-----------------|---------------|
| 29 | `sql/29_guc_settings.sql` | Key GUC review | `source = 'default'` on memory |
| 30 | `sql/30_buffer_cache_hit.sql` | Cache hit ratio per table | `hit_ratio_pct < 95%` |
| 31 | `sql/31_checkpoint_pressure.sql` | Forced checkpoints, backend fsync | `forced_pct > 10%` |
| 32 | `sql/32_database_summary.sql` | DB-level rollbacks, deadlocks | `rollback_pct > 5%`, `deadlocks > 0` |
