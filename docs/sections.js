// pgvitals — Section data
// All 32 diagnostic sections with metadata and SQL queries.

const SECTIONS = [
  {
    id: '01',
    title: 'Slow / Expensive Queries',
    area: 'Query Behavior',
    areaSlug: 'query',
    what: 'Top queries ranked by total CPU time consumed since last stats reset.',
    lookFor: 'mean_exec_ms > 100 | pct_total_time > 10%',
    action: 'EXPLAIN ANALYZE the top offenders; add indexes or rewrite query logic.',
    requires: 'pg_stat_statements',
    sql: `SELECT
    round(total_exec_time::numeric, 2)                                        AS total_exec_ms,
    calls,
    round(mean_exec_time::numeric, 2)                                         AS mean_exec_ms,
    round(stddev_exec_time::numeric, 2)                                       AS stddev_exec_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS pct_total_time,
    rows,
    round(rows::numeric / nullif(calls, 0), 2)                               AS rows_per_call,
    round(shared_blks_hit::numeric
        / nullif(shared_blks_hit + shared_blks_read, 0) * 100, 2)            AS cache_hit_pct,
    left(query, 200)                                                           AS query_snippet
FROM pg_stat_statements
WHERE calls > 10
ORDER BY total_exec_time DESC
LIMIT 25;`
  },
  {
    id: '02',
    title: 'Temp File & work_mem Pressure',
    area: 'Query Behavior',
    areaSlug: 'query',
    what: 'Queries spilling intermediate results to disk because work_mem is too small.',
    lookFor: 'Any temp_written_mb > 0 — every MB is a disk write',
    action: 'Increase work_mem for the session; tune join/sort strategy.',
    requires: 'pg_stat_statements',
    sql: `SELECT
    calls,
    round(mean_exec_time::numeric, 2)                                AS mean_exec_ms,
    temp_blks_written,
    round((temp_blks_written * 8192.0 / 1024 / 1024)::numeric, 2)  AS temp_written_mb,
    temp_blks_read,
    round((temp_blks_read * 8192.0 / 1024 / 1024)::numeric, 2)     AS temp_read_mb,
    left(query, 200)                                                  AS query_snippet
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 20;`
  },
  {
    id: '03',
    title: 'Sequential Scan Hotspots',
    area: 'Query Behavior',
    areaSlug: 'query',
    what: 'Tables hit mostly with full sequential scans — a missing index signal.',
    lookFor: 'seq_scan_pct > 50% on tables with n_live_tup > 10k',
    action: 'Add a targeted index on the filtered columns; verify with EXPLAIN.',
    sql: `SELECT
    schemaname,
    relname AS tablename,
    seq_scan,
    seq_tup_read,
    idx_scan,
    round(seq_scan::numeric / nullif(seq_scan + idx_scan, 0) * 100, 2)    AS seq_scan_pct,
    n_live_tup,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size
FROM pg_stat_user_tables
WHERE seq_scan > 0
  AND n_live_tup > 10000
ORDER BY seq_scan DESC
LIMIT 20;`
  },
  {
    id: '04',
    title: 'N+1 Patterns',
    area: 'Query Behavior',
    areaSlug: 'query',
    what: 'Fast queries called thousands of times — classic ORM N+1 symptom.',
    lookFor: 'calls > 10,000 and mean_exec_ms < 10',
    action: 'Batch with IN clause; enable ORM eager loading; use prepared statements.',
    requires: 'pg_stat_statements',
    sql: `SELECT
    calls,
    round(mean_exec_time::numeric, 4)                              AS mean_exec_ms,
    round(total_exec_time::numeric, 2)                             AS total_exec_ms,
    round(rows::numeric / nullif(calls, 0), 2)                    AS rows_per_call,
    left(query, 200)                                               AS query_snippet
FROM pg_stat_statements
WHERE calls > 10000
  AND mean_exec_time < 10
ORDER BY calls DESC
LIMIT 20;`
  },
  {
    id: '05',
    title: 'JIT Compilation Overhead',
    area: 'Query Behavior',
    areaSlug: 'query',
    what: 'Queries where JIT compilation time exceeds its execution benefit.',
    lookFor: 'total_jit_ms close to or greater than mean_exec_ms',
    action: 'SET jit = off for the session; raise jit_above_cost in postgresql.conf.',
    requires: 'pg_stat_statements, PostgreSQL 14+',
    sql: `SELECT
    calls,
    round(mean_exec_time::numeric, 2)                                   AS mean_exec_ms,
    jit_functions,
    round(jit_generation_time::numeric, 2)                              AS jit_gen_ms,
    round(jit_inlining_time::numeric, 2)                                AS jit_inline_ms,
    round(jit_optimization_time::numeric, 2)                            AS jit_opt_ms,
    round(jit_emission_time::numeric, 2)                                AS jit_emit_ms,
    round((jit_generation_time + jit_inlining_time
           + jit_optimization_time + jit_emission_time)::numeric, 2)   AS total_jit_ms,
    left(query, 200)                                                     AS query_snippet
FROM pg_stat_statements
WHERE jit_functions > 0
ORDER BY jit_generation_time + jit_inlining_time
         + jit_optimization_time + jit_emission_time DESC
LIMIT 15;`
  },
  {
    id: '06',
    title: 'Unused Indexes',
    area: 'Index Health',
    areaSlug: 'index',
    what: 'Indexes never used in a query scan since the last pg_stat_reset.',
    lookFor: 'idx_scan = 0 on non-primary, non-unique indexes',
    action: 'DROP after verifying; check stats_reset date first.',
    sql: `SELECT
    s.schemaname,
    s.relname AS tablename,
    s.indexrelname AS indexname,
    pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
    s.idx_scan,
    s.idx_tup_read,
    s.idx_tup_fetch
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisprimary
  AND NOT i.indisunique
  AND pg_relation_size(s.indexrelid) > 0
ORDER BY pg_relation_size(s.indexrelid) DESC;

-- Stats reset time (judge staleness of idx_scan = 0)
SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();`
  },
  {
    id: '07',
    title: 'Duplicate / Redundant Indexes',
    area: 'Index Health',
    areaSlug: 'index',
    what: 'Multiple indexes covering the exact same column set.',
    lookFor: 'Any row — duplicates add write overhead with no query benefit.',
    action: 'Keep the most specific one; DROP the rest.',
    sql: `SELECT
    indrelid::regclass                                                      AS table_name,
    array_agg(indexrelid::regclass ORDER BY indexrelid)                    AS duplicate_indexes,
    array_agg(
        pg_size_pretty(pg_relation_size(indexrelid)) ORDER BY indexrelid
    )                                                                       AS sizes,
    indkey::text                                                            AS index_columns
FROM pg_index
GROUP BY indrelid, indkey
HAVING count(*) > 1
ORDER BY indrelid::regclass::text;`
  },
  {
    id: '08',
    title: 'Invalid Indexes',
    area: 'Index Health',
    areaSlug: 'index',
    what: 'Indexes left in invalid state — typically from a failed CREATE INDEX CONCURRENTLY.',
    lookFor: 'Any row — invalid indexes waste space and are never used by the planner.',
    action: 'DROP index_name; then recreate with CONCURRENTLY.',
    sql: `SELECT
    n.nspname                                              AS schemaname,
    c.relname                                              AS tablename,
    i.relname                                              AS indexname,
    pg_size_pretty(pg_relation_size(i.oid))               AS wasted_size
FROM pg_index x
JOIN pg_class c ON c.oid = x.indrelid
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT x.indisvalid
  AND n.nspname NOT IN ('pg_catalog', 'information_schema');`
  },
  {
    id: '09',
    title: 'Missing Foreign Key Indexes',
    area: 'Index Health',
    areaSlug: 'index',
    what: 'FK columns without a supporting index — causes seq scans on joins and cascades.',
    lookFor: 'Any row — almost always worth indexing.',
    action: 'CREATE INDEX ON table(fk_column);',
    sql: `SELECT
    c.conrelid::regclass                                              AS table_name,
    c.conname                                                         AS constraint_name,
    string_agg(a.attname, ', ' ORDER BY x.n)                        AS fk_columns
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum
WHERE c.contype = 'f'
  AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.conrelid
        AND (i.indkey::int2[])[0 : array_length(c.conkey, 1) - 1]
            @> c.conkey
  )
GROUP BY c.conrelid, c.conname
ORDER BY table_name;`
  },
  {
    id: '10',
    title: 'Index Bloat',
    area: 'Index Health',
    areaSlug: 'index',
    what: 'Indexes with high fragmentation — free-space waste from deletes and updates.',
    lookFor: 'bloat_pct_estimate > 30% on large indexes',
    action: 'REINDEX CONCURRENTLY indexname',
    sql: `WITH index_info AS (
    SELECT
        n.nspname                                              AS schemaname,
        ct.relname                                             AS tablename,
        ci.relname                                             AS indexname,
        pg_relation_size(ci.oid)                               AS index_bytes,
        ci.relpages                                            AS actual_pages,
        ceil(ci.reltuples * 14
             / (current_setting('block_size')::int * 0.8)
        )                                                      AS estimated_min_pages
    FROM pg_index x
    JOIN pg_class ci ON ci.oid = x.indexrelid
    JOIN pg_class ct ON ct.oid = x.indrelid
    JOIN pg_namespace n ON n.oid = ci.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND ci.relpages > 0
)
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(index_bytes)                                            AS index_size,
    actual_pages,
    estimated_min_pages::int,
    round(
        ((1 - estimated_min_pages / nullif(actual_pages, 0)) * 100)::numeric, 2
    )                                                                      AS bloat_pct_estimate
FROM index_info
WHERE index_bytes > 1024 * 1024
  AND actual_pages > estimated_min_pages
ORDER BY index_bytes DESC
LIMIT 20;`
  },
  {
    id: '11',
    title: 'Table Bloat',
    area: 'Tables & Storage',
    areaSlug: 'table',
    what: 'Tables with large amounts of dead / unreclaimable space.',
    lookFor: 'bloat_pct_estimate > 20% | bloat size > 100 MB',
    action: 'VACUUM ANALYZE table (online); pg_repack (no lock); or VACUUM FULL (full lock).',
    sql: `WITH constants AS (
    SELECT current_setting('block_size')::int AS bs,
           23 AS hdr, 8 AS ma
),
per_table AS (
    SELECT
        ns.nspname AS schemaname, tbl.relname AS tablename,
        tbl.relpages, tbl.reltuples, bs,
        (sum((1 - s.null_frac) * s.avg_width)::int + hdr + ma
          - CASE WHEN hdr % ma = 0 THEN ma ELSE hdr % ma END) AS row_data_width
    FROM pg_class tbl
    JOIN pg_namespace ns    ON ns.oid = tbl.relnamespace
    JOIN pg_attribute att   ON att.attrelid = tbl.oid AND att.attnum > 0 AND NOT att.attisdropped
    JOIN pg_stats s         ON s.schemaname = ns.nspname AND s.tablename = tbl.relname
                            AND s.attname = att.attname
    CROSS JOIN constants
    WHERE tbl.relkind = 'r' AND ns.nspname NOT IN ('pg_catalog','information_schema')
    GROUP BY ns.nspname, tbl.relname, tbl.relpages, tbl.reltuples, bs, hdr, ma
)
SELECT
    schemaname, tablename,
    relpages                                                           AS actual_pages,
    round(reltuples)                                                   AS est_row_count,
    pg_size_pretty((relpages * bs)::bigint)                           AS total_size,
    pg_size_pretty(
        greatest(0, relpages - ceil(reltuples * row_data_width / bs))::bigint * bs
    )                                                                  AS bloat_size_estimate,
    round(
        (greatest(0, 1 - ceil(reltuples * row_data_width / bs)
                        / nullif(relpages, 0)) * 100)::numeric, 2
    )                                                                  AS bloat_pct_estimate
FROM per_table
WHERE relpages > 10
ORDER BY greatest(0, relpages - ceil(reltuples * row_data_width / bs)) DESC
LIMIT 20;`
  },
  {
    id: '12',
    title: 'TOAST Table Bloat',
    area: 'Tables & Storage',
    areaSlug: 'table',
    what: 'Oversized TOAST tables storing large column values (text, jsonb, bytea, arrays).',
    lookFor: 'toast_to_table_pct > 200% — TOAST larger than the main table',
    action: 'VACUUM the parent table; consider compressing values at the application layer.',
    sql: `SELECT
    n.nspname                                                         AS schemaname,
    c.relname                                                         AS tablename,
    pg_size_pretty(pg_relation_size(c.oid))                          AS table_size,
    pg_size_pretty(pg_relation_size(t.oid))                          AS toast_size,
    round(
        pg_relation_size(t.oid)::numeric
        / nullif(pg_relation_size(c.oid), 0) * 100, 2
    )                                                                 AS toast_to_table_pct
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_class t     ON t.oid = c.reltoastrelid
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND pg_relation_size(t.oid) > 1024 * 1024
ORDER BY pg_relation_size(t.oid) DESC
LIMIT 20;`
  },
  {
    id: '13',
    title: 'Table & Index Size Ranking',
    area: 'Tables & Storage',
    areaSlug: 'table',
    what: 'Largest objects ranked by total, heap, index, and TOAST size.',
    lookFor: 'indexes_size >> heap_size (over-indexed); unexpected size growth.',
    action: 'Investigate large objects; review index necessity.',
    sql: `SELECT
    schemaname,
    tablename,
    pg_size_pretty(
        pg_total_relation_size(schemaname || '.' || tablename)
    )                                                                  AS total_size,
    pg_size_pretty(
        pg_relation_size(schemaname || '.' || tablename)
    )                                                                  AS heap_size,
    pg_size_pretty(
        pg_indexes_size(schemaname || '.' || tablename)
    )                                                                  AS indexes_size,
    pg_size_pretty(
        pg_total_relation_size(schemaname || '.' || tablename)
        - pg_relation_size(schemaname || '.' || tablename)
        - pg_indexes_size(schemaname || '.' || tablename)
    )                                                                  AS toast_size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
LIMIT 30;`
  },
  {
    id: '14',
    title: 'Table Access Patterns',
    area: 'Tables & Storage',
    areaSlug: 'table',
    what: 'Heap vs index fetch ratio, write load, and dead tuple ratio per table.',
    lookFor: 'High seq_tup_read + low idx_tup_fetch → missing index | dead_pct > 10% → vacuum urgently needed',
    action: 'Add index for seq scan tables; run VACUUM ANALYZE for high dead_pct.',
    sql: `SELECT
    schemaname,
    relname AS tablename,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    n_tup_ins,
    n_tup_upd,
    n_tup_del,
    n_tup_hot_upd,
    n_live_tup,
    n_dead_tup,
    round(
        n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 2
    )                                                                  AS dead_pct
FROM pg_stat_user_tables
ORDER BY seq_tup_read + idx_tup_fetch DESC
LIMIT 25;`
  },
  {
    id: '15',
    title: 'Autovacuum Worker Activity',
    area: 'Vacuum & Stats',
    areaSlug: 'vacuum',
    what: 'Currently running vacuum workers and their per-table progress.',
    lookFor: 'Stuck workers (pct_done not advancing); index_vacuum_count = 0 on large tables.',
    action: 'Check autovacuum_max_workers; investigate I/O contention.',
    sql: `SELECT
    pid,
    datname,
    relid::regclass                                                    AS table_name,
    phase,
    heap_blks_total,
    heap_blks_scanned,
    heap_blks_vacuumed,
    round(
        heap_blks_vacuumed::numeric / nullif(heap_blks_total, 0) * 100, 2
    )                                                                  AS pct_done,
    index_vacuum_count,
    max_dead_tuples,
    num_dead_tuples
FROM pg_stat_progress_vacuum;

-- Active autovacuum worker count
SELECT count(*) AS active_autovacuum_workers
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker';`
  },
  {
    id: '16',
    title: 'Dead Tuple Urgency',
    area: 'Vacuum & Stats',
    areaSlug: 'vacuum',
    what: 'Tables accumulating dead tuples faster than vacuum clears them.',
    lookFor: 'dead_pct > 10% | last_autovacuum = NULL or many days ago',
    action: 'VACUUM ANALYZE tablename; lower autovacuum_vacuum_scale_factor.',
    sql: `SELECT
    schemaname,
    relname AS tablename,
    n_dead_tup,
    n_live_tup,
    round(
        n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 2
    )                                                                  AS dead_pct,
    n_mod_since_analyze,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    pg_size_pretty(
        pg_relation_size(relid)
    )                                                                  AS table_size
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 25;`
  },
  {
    id: '17',
    title: 'Stale Statistics',
    area: 'Vacuum & Stats',
    areaSlug: 'vacuum',
    what: 'Tables with many row modifications since last ANALYZE — causes bad query plans.',
    lookFor: 'mod_pct > 10% | time_since_analyze > 1 day on hot tables',
    action: 'ANALYZE tablename; lower autovacuum_analyze_scale_factor for busy tables.',
    sql: `SELECT
    schemaname,
    relname AS tablename,
    n_live_tup,
    n_mod_since_analyze,
    round(
        n_mod_since_analyze::numeric / nullif(n_live_tup, 0) * 100, 2
    )                                                                  AS mod_pct,
    last_analyze,
    last_autoanalyze,
    now() - greatest(last_analyze, last_autoanalyze)                  AS time_since_analyze
FROM pg_stat_user_tables
WHERE n_live_tup > 1000
ORDER BY n_mod_since_analyze DESC
LIMIT 20;`
  },
  {
    id: '18',
    title: 'Long-Running Transactions',
    area: 'Vacuum & Stats',
    areaSlug: 'vacuum',
    what: 'Open transactions blocking autovacuum and holding locks.',
    lookFor: 'xact_duration > 5 minutes',
    action: 'SELECT pg_terminate_backend(pid) after investigation; set idle_in_transaction_session_timeout.',
    sql: `SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    now() - xact_start                                                AS xact_duration,
    now() - query_start                                               AS query_duration,
    left(query, 200)                                                   AS current_query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes'
  AND pid <> pg_backend_pid()
ORDER BY xact_start ASC;`
  },
  {
    id: '19',
    title: 'Connection Saturation',
    area: 'Connections & Locks',
    areaSlug: 'connections',
    what: 'Current connections vs max_connections — headroom remaining.',
    lookFor: 'used_pct > 80% — approaching the connection limit',
    action: 'Add PgBouncer; audit idle connections; reduce application pool size.',
    sql: `-- Summary
SELECT
    count(*)                                                               AS total,
    count(*) FILTER (WHERE state = 'active')                              AS active,
    count(*) FILTER (WHERE state = 'idle')                                AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction')                 AS idle_in_txn,
    count(*) FILTER (WHERE state = 'idle in transaction (aborted)')       AS idle_in_txn_aborted,
    count(*) FILTER (WHERE wait_event IS NOT NULL AND state = 'active')   AS waiting,
    s.setting::int                                                         AS max_connections,
    round(count(*)::numeric / s.setting::int * 100, 2)                   AS used_pct,
    s.setting::int - count(*)                                              AS free_slots
FROM pg_stat_activity, pg_settings s
WHERE s.name = 'max_connections' AND pg_stat_activity.pid <> pg_backend_pid()
GROUP BY s.setting;

-- Per application breakdown
SELECT application_name, state, count(*) AS connections
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY application_name, state
ORDER BY count(*) DESC LIMIT 20;`
  },
  {
    id: '20',
    title: 'Idle-in-Transaction',
    area: 'Connections & Locks',
    areaSlug: 'connections',
    what: 'Sessions sitting idle inside an open transaction — silently hold locks and block autovacuum.',
    lookFor: 'idle_duration > 30 seconds',
    action: 'Fix application to commit/rollback promptly; SET idle_in_transaction_session_timeout = \'30s\'.',
    sql: `SELECT
    pid,
    usename,
    application_name,
    client_addr,
    now() - state_change                                              AS idle_duration,
    now() - xact_start                                                AS txn_open_duration,
    left(query, 200)                                                   AS last_query
FROM pg_stat_activity
WHERE state IN ('idle in transaction', 'idle in transaction (aborted)')
ORDER BY state_change ASC;`
  },
  {
    id: '21',
    title: 'Lock Wait Tree',
    area: 'Connections & Locks',
    areaSlug: 'connections',
    what: 'Full chain of who is blocking whom.',
    lookFor: 'Any row — every lock wait degrades throughput.',
    action: 'Identify root blocker (where blocking_pids = \'{}\') and investigate or terminate.',
    sql: `-- Blocking summary
SELECT
    pid                                                                AS blocked_pid,
    usename                                                            AS blocked_user,
    pg_blocking_pids(pid)                                             AS blocking_pids,
    cardinality(pg_blocking_pids(pid))                                AS blocking_depth,
    wait_event_type,
    wait_event,
    state,
    now() - query_start                                               AS waiting_duration,
    left(query, 200)                                                   AS blocked_query
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0
ORDER BY waiting_duration DESC;

-- Detailed lock mode breakdown
SELECT l.pid, l.locktype, l.relation::regclass AS locked_object,
       l.mode, l.granted, a.usename, a.state, left(a.query, 150) AS query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE NOT l.granted
   OR l.pid IN (
       SELECT unnest(pg_blocking_pids(pid))
       FROM pg_stat_activity
       WHERE cardinality(pg_blocking_pids(pid)) > 0
   )
ORDER BY l.pid;`
  },
  {
    id: '22',
    title: 'Wait Events Breakdown',
    area: 'Connections & Locks',
    areaSlug: 'connections',
    what: 'What all active sessions are currently waiting on.',
    lookFor: 'Lock/LWLock waits > a few sessions; IO:DataFileRead spikes (I/O bound).',
    action: 'Cross-reference with lock tree; investigate I/O if DataFileRead dominates.',
    sql: `SELECT
    wait_event_type,
    wait_event,
    count(*)                                                          AS sessions,
    array_agg(pid ORDER BY pid)                                      AS pids
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
  AND pid <> pg_backend_pid()
GROUP BY wait_event_type, wait_event
ORDER BY sessions DESC;`
  },
  {
    id: '23',
    title: 'Streaming Replication Lag',
    area: 'Replication',
    areaSlug: 'replication',
    what: 'Per-standby write, flush, and replay lag.',
    lookFor: 'replay_lag > 30s | flush_lag > 10s',
    action: 'Check standby I/O; verify network throughput; review recovery configuration.',
    requires: 'streaming replication configured',
    sql: `SELECT
    application_name,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    write_lag,
    flush_lag,
    replay_lag,
    sync_state,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)
    )                                                                 AS unsent_wal
FROM pg_stat_replication
ORDER BY replay_lag DESC NULLS LAST;`
  },
  {
    id: '24',
    title: 'Logical Replication Slot Lag',
    area: 'Replication',
    areaSlug: 'replication',
    what: 'WAL accumulating for logical replication consumers.',
    lookFor: 'consumer_lag_size > 500 MB — risk of disk exhaustion.',
    action: 'Check consumer health; if consumer is gone: SELECT pg_drop_replication_slot(\'name\').',
    requires: 'logical replication slots configured',
    sql: `SELECT
    slot_name,
    plugin,
    database,
    active,
    active_pid,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
    )                                                                 AS consumer_lag_size,
    pg_wal_lsn_diff(
        pg_current_wal_lsn(), confirmed_flush_lsn
    )                                                                 AS consumer_lag_bytes
FROM pg_replication_slots
WHERE slot_type = 'logical'
ORDER BY consumer_lag_bytes DESC NULLS LAST;`
  },
  {
    id: '25',
    title: 'Replication Slot WAL Retention',
    area: 'Replication',
    areaSlug: 'replication',
    what: 'Total WAL held on disk by ALL slots (streaming + logical).',
    lookFor: 'wal_retained approaching your pg_wal partition free space.',
    action: 'Drop inactive slots; advance or drop lagging slots.',
    requires: 'replication slots exist',
    sql: `SELECT
    slot_name,
    slot_type,
    active,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    )                                                                 AS wal_retained,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)               AS wal_retained_bytes
FROM pg_replication_slots
ORDER BY wal_retained_bytes DESC NULLS LAST;

-- Total WAL held across all slots
SELECT pg_size_pretty(
    sum(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
) AS total_wal_held_by_slots
FROM pg_replication_slots;`
  },
  {
    id: '26',
    title: 'XID Wraparound Risk',
    area: 'Risk Signals',
    areaSlug: 'risk',
    what: 'Distance from transaction ID exhaustion (hard limit: ~2 billion XIDs).',
    lookFor: 'xid_age > 1.5B → emergency VACUUM FREEZE; pct_used > 70% → plan maintenance.',
    action: 'VACUUM FREEZE on oldest tables; lower autovacuum_freeze_max_age.',
    sql: `-- Database level
SELECT
    datname,
    age(datfrozenxid)                                                 AS xid_age,
    2147483647 - age(datfrozenxid)                                   AS xid_remaining,
    round(age(datfrozenxid)::numeric / 2147483647 * 100, 2)         AS pct_used
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Table level (top 20 oldest)
SELECT
    n.nspname AS schemaname, c.relname AS tablename,
    age(c.relfrozenxid) AS xid_age,
    round(age(c.relfrozenxid)::numeric / 2147483647 * 100, 2) AS pct_used,
    pg_size_pretty(pg_relation_size(c.oid)) AS table_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 20;`
  },
  {
    id: '27',
    title: 'MultiXact ID Wraparound Risk',
    area: 'Risk Signals',
    areaSlug: 'risk',
    what: 'Distance from MultiXact exhaustion — a separate counter used for row-level locks.',
    lookFor: 'mxid_age > 1 billion → tables need VACUUM FREEZE',
    action: 'VACUUM FREEZE tablename; lower autovacuum_multixact_freeze_max_age.',
    sql: `SELECT
    datname,
    mxid_age(datminmxid)                                             AS mxid_age,
    2147483647 - mxid_age(datminmxid)                               AS mxid_remaining,
    round(mxid_age(datminmxid)::numeric / 2147483647 * 100, 2)     AS pct_used
FROM pg_database
ORDER BY mxid_age(datminmxid) DESC;`
  },
  {
    id: '28',
    title: 'Sequence Exhaustion Risk',
    area: 'Risk Signals',
    areaSlug: 'risk',
    what: 'Sequences approaching their maximum value — integer overflow causes INSERT failures.',
    lookFor: 'pct_used > 80% on bigint; any significant % on int (max = 2.1B).',
    action: 'ALTER SEQUENCE seq MAXVALUE new_max; or ALTER COLUMN type TO bigint.',
    sql: `SELECT
    schemaname,
    sequencename,
    data_type,
    last_value,
    min_value,
    max_value,
    increment_by,
    cycle,
    round(
        (last_value - min_value)::numeric
        / nullif(max_value - min_value, 0) * 100, 2
    )                                                                 AS pct_used,
    (max_value - last_value) / nullif(increment_by, 0)               AS values_remaining
FROM pg_sequences
WHERE NOT cycle
  AND last_value IS NOT NULL
ORDER BY pct_used DESC NULLS LAST
LIMIT 20;`
  },
  {
    id: '29',
    title: 'Key GUC Settings Review',
    area: 'Config & Health',
    areaSlug: 'config',
    what: 'Critical configuration parameters and their source (default vs tuned).',
    lookFor: 'source = \'default\' on memory/checkpoint settings — often too conservative for production.',
    action: 'Tune in postgresql.conf; reload with SELECT pg_reload_conf().',
    sql: `SELECT
    name, setting, unit, source, short_desc
FROM pg_settings
WHERE name IN (
    'shared_buffers', 'work_mem', 'maintenance_work_mem', 'effective_cache_size',
    'checkpoint_timeout', 'checkpoint_completion_target',
    'max_wal_size', 'min_wal_size', 'wal_level', 'wal_compression',
    'autovacuum', 'autovacuum_max_workers', 'autovacuum_vacuum_cost_delay',
    'autovacuum_vacuum_scale_factor', 'autovacuum_analyze_scale_factor',
    'autovacuum_freeze_max_age',
    'max_connections', 'superuser_reserved_connections',
    'idle_in_transaction_session_timeout', 'statement_timeout',
    'max_parallel_workers_per_gather', 'max_worker_processes', 'max_parallel_workers',
    'random_page_cost', 'seq_page_cost', 'effective_io_concurrency',
    'enable_jit', 'jit_above_cost',
    'log_min_duration_statement', 'log_lock_waits',
    'deadlock_timeout', 'log_temp_files', 'lock_timeout'
)
ORDER BY
    CASE
        WHEN name LIKE '%buffer%' OR name LIKE '%mem%'     THEN 1
        WHEN name LIKE '%checkpoint%' OR name LIKE '%wal%' THEN 2
        WHEN name LIKE '%autovacuum%'                      THEN 3
        WHEN name LIKE '%connection%' OR name LIKE '%timeout%' THEN 4
        ELSE 5
    END, name;`
  },
  {
    id: '30',
    title: 'Buffer Cache Hit Ratio',
    area: 'Config & Health',
    areaSlug: 'config',
    what: 'How often reads are served from shared_buffers vs disk, per table and globally.',
    lookFor: 'hit_ratio_pct < 95% on hot tables',
    action: 'Increase shared_buffers; investigate seq scan storms evicting hot pages.',
    sql: `-- Per table
SELECT
    schemaname, relname AS tablename,
    heap_blks_read, heap_blks_hit,
    round(heap_blks_hit::numeric
        / nullif(heap_blks_read + heap_blks_hit, 0) * 100, 2)        AS hit_ratio_pct,
    idx_blks_read, idx_blks_hit,
    round(idx_blks_hit::numeric
        / nullif(idx_blks_read + idx_blks_hit, 0) * 100, 2)          AS idx_hit_ratio_pct
FROM pg_statio_user_tables
WHERE heap_blks_read + heap_blks_hit > 1000
ORDER BY heap_blks_read DESC
LIMIT 20;

-- Global database hit ratio
SELECT
    sum(blks_hit) AS total_hits,
    sum(blks_read) AS total_reads,
    round(sum(blks_hit)::numeric
        / nullif(sum(blks_hit) + sum(blks_read), 0) * 100, 2) AS global_hit_ratio_pct
FROM pg_stat_database
WHERE datname NOT IN ('template0','template1');`
  },
  {
    id: '31',
    title: 'Checkpoint & WAL Pressure',
    area: 'Config & Health',
    areaSlug: 'config',
    what: 'Whether checkpoints are forced too frequently and whether backends are writing directly to disk.',
    lookFor: 'forced_pct > 10% → increase max_wal_size | buffers_backend_fsync > 0 → critical',
    action: 'Increase max_wal_size; set checkpoint_completion_target = 0.9.',
    sql: `SELECT
    checkpoints_timed,
    checkpoints_req,
    round(
        checkpoints_req::numeric
        / nullif(checkpoints_timed + checkpoints_req, 0) * 100, 2
    )                                                                 AS forced_pct,
    round((checkpoint_write_time / 1000)::numeric, 2)                AS write_time_sec,
    round((checkpoint_sync_time / 1000)::numeric, 2)                 AS sync_time_sec,
    buffers_checkpoint,
    buffers_clean,
    maxwritten_clean,
    buffers_backend,
    buffers_backend_fsync,
    buffers_alloc,
    now() - stats_reset                                               AS stats_age
FROM pg_stat_bgwriter;`
  },
  {
    id: '32',
    title: 'Database-Level Summary',
    area: 'Config & Health',
    areaSlug: 'config',
    what: 'Per-database throughput, cache hit ratio, deadlocks, and temp usage at a glance.',
    lookFor: 'rollback_pct > 5% | deadlocks > 0 | cache_hit_pct < 95%',
    action: 'Investigate rollback sources; add deadlock_timeout logging; tune shared_buffers.',
    sql: `SELECT
    datname,
    numbackends                                                        AS active_backends,
    xact_commit,
    xact_rollback,
    round(
        xact_rollback::numeric / nullif(xact_commit + xact_rollback, 0) * 100, 2
    )                                                                  AS rollback_pct,
    round(
        blks_hit::numeric / nullif(blks_read + blks_hit, 0) * 100, 2
    )                                                                  AS cache_hit_pct,
    tup_inserted, tup_updated, tup_deleted,
    conflicts,
    temp_files,
    pg_size_pretty(temp_bytes)                                        AS temp_usage,
    deadlocks,
    pg_size_pretty(pg_database_size(datname))                        AS db_size,
    now() - stats_reset                                               AS stats_age
FROM pg_stat_database
WHERE datname NOT IN ('template0','template1')
ORDER BY numbackends DESC;`
  },
  {
    id: '33',
    title: 'WAL Generation Rate',
    area: 'Config & Health',
    areaSlug: 'config',
    what: 'WAL (Write-Ahead Log) generation volume and rate since stats reset.',
    lookFor: 'High wal_mb_per_hour (e.g. > 1000 MB/hr) | high fpi_pct (> 20%)',
    action: 'Enable wal_compression; tune max_wal_size and checkpoint_timeout.',
    requires: 'PostgreSQL 14+',
    sql: `SELECT
    wal_records,
    wal_fpi,
    pg_size_pretty(wal_bytes)                                                 AS total_wal_size,
    round(wal_bytes / 1024.0 / 1024.0, 2)                                     AS total_wal_mb,
    round(
        (wal_bytes / 1024.0 / 1024.0)
        / nullif(extract(epoch from (now() - stats_reset)) / 3600.0, 0)::numeric, 2
    )                                                                          AS wal_mb_per_hour,
    round(
        wal_fpi::numeric / nullif(wal_records, 0) * 100, 2
    )                                                                          AS fpi_pct,
    stats_reset
FROM pg_stat_wal;`
  },
  {
    id: '34',
    title: 'Partitioned Table Health',
    area: 'Tables & Storage',
    areaSlug: 'table',
    what: 'Partitioned tables, partition counts, and total sizes.',
    lookFor: 'partition_count > 100 | partition_count = 0',
    action: 'Merge old partitions or partition by larger range; create missing partitions.',
    sql: `SELECT
    n.nspname                                                                  AS schemaname,
    c.relname                                                                  AS table_name,
    count(i.inhrelid)                                                          AS partition_count,
    pg_size_pretty(pg_total_relation_size(c.oid))                              AS total_size,
    pg_size_pretty(pg_relation_size(c.oid))                                    AS parent_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_inherits i ON i.inhparent = c.oid
WHERE c.relkind = 'p'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
GROUP BY n.nspname, c.relname, c.oid
ORDER BY partition_count DESC;`
  },
  {
    id: '35',
    title: 'Open Prepared Transactions',
    area: 'Critical Risk Signals',
    areaSlug: 'risk',
    what: 'Uncommitted prepared transactions (2PC/two-phase commit).',
    lookFor: 'Any row older than 5 minutes (blocks vacuum, holds locks)',
    action: 'Run COMMIT PREPARED '<gid>'; or ROLLBACK PREPARED '<gid>';.',
    sql: `SELECT
    gid,
    prepared,
    owner,
    database,
    now() - prepared                                                          AS age,
    transaction::text                                                          AS xid
FROM pg_prepared_xacts
ORDER BY prepared ASC;`
  },
  {
    id: '36',
    title: 'I/O Stats by Backend (pg_stat_io)',
    area: 'Config & Health',
    areaSlug: 'config',
    what: 'I/O statistics broken down by backend type, target object, and context.',
    lookFor: 'High evictions | high temp relation reads/writes',
    action: 'Increase work_mem if temp relation I/O is high; increase shared_buffers if evictions are high; tune checkpointer if writes dominate backends.',
    requires: 'PostgreSQL 16+, track_io_timing = on (optional for timings)',
    sql: `SELECT
    backend_type,
    object,
    context,
    reads,
    round(read_time::numeric, 2)                                              AS read_time_ms,
    writes,
    round(write_time::numeric, 2)                                             AS write_time_ms,
    hits,
    evictions,
    round(reads::numeric / nullif(reads + hits, 0) * 100, 2)                  AS read_pct
FROM pg_stat_io
WHERE reads + writes + hits > 0
ORDER BY reads + writes DESC;`
  }
];
