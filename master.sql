-- ============================================================
-- PostgreSQL Performance Diagnostics Master File
-- Target: PostgreSQL 14+
-- Usage:
--   Ad-hoc  : Run any section independently in psql or pgAdmin
--   Periodic: SET search_path TO perf_monitor; SELECT capture_snapshot('label');
-- Prerequisites:
--   CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
--   pg_stat_statements must be in shared_preload_libraries
-- ============================================================


-- ============================================================
-- SECTION 00 · PREREQUISITES CHECK
-- What    : Confirm your database environment is ready for pgvitals
-- Look for: has_pg_monitor = true and pg_stat_statements installed
-- Action  : Install pg_stat_statements; grant pg_monitor role to your user
-- Requires: pg_stat_statements in shared_preload_libraries
-- ============================================================

-- Check pg_stat_statements is active
SELECT name, setting FROM pg_settings WHERE name = 'shared_preload_libraries';

-- Check extension is installed
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_stat_statements';

-- Check current user has sufficient privileges
SELECT current_user, pg_has_role(current_user, 'pg_monitor', 'MEMBER') AS has_pg_monitor;


-- ============================================================
-- PART A · MONITORING SCHEMA
-- (Run once before load test; skip for pure ad-hoc use)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS perf_monitor;

-- Snapshot registry -------------------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.snapshots (
    snapshot_id  BIGSERIAL PRIMARY KEY,
    captured_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    label        TEXT,   -- 'baseline','ramp_up','peak','cooldown'
    notes        TEXT
);

-- Slow queries ------------------------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.slow_queries (
    snapshot_id      BIGINT REFERENCES perf_monitor.snapshots,
    captured_at      TIMESTAMPTZ,
    queryid          BIGINT,
    calls            BIGINT,
    total_exec_ms    NUMERIC,
    mean_exec_ms     NUMERIC,
    pct_total_time   NUMERIC,
    temp_blks_written BIGINT,
    rows_per_call    NUMERIC,
    query_snippet    TEXT
);

-- Connections -------------------------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.connections (
    snapshot_id      BIGINT REFERENCES perf_monitor.snapshots,
    captured_at      TIMESTAMPTZ,
    total            INT,
    active           INT,
    idle             INT,
    idle_in_txn      INT,
    idle_in_txn_aborted INT,
    waiting          INT,
    max_connections  INT,
    used_pct         NUMERIC
);

-- Lock waits --------------------------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.lock_waits (
    snapshot_id      BIGINT REFERENCES perf_monitor.snapshots,
    captured_at      TIMESTAMPTZ,
    blocked_pid      INT,
    blocked_user     TEXT,
    blocking_pids    INT[],
    wait_event_type  TEXT,
    wait_event       TEXT,
    blocked_duration INTERVAL,
    query_snippet    TEXT
);

-- Wait events -------------------------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.wait_events (
    snapshot_id      BIGINT REFERENCES perf_monitor.snapshots,
    captured_at      TIMESTAMPTZ,
    wait_event_type  TEXT,
    wait_event       TEXT,
    session_count    INT
);

-- Table stats snapshot ----------------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.table_stats (
    snapshot_id      BIGINT REFERENCES perf_monitor.snapshots,
    captured_at      TIMESTAMPTZ,
    schemaname       TEXT,
    tablename        TEXT,
    seq_scan         BIGINT,
    seq_tup_read     BIGINT,
    idx_scan         BIGINT,
    n_dead_tup       BIGINT,
    n_live_tup       BIGINT,
    heap_blks_hit    BIGINT,
    heap_blks_read   BIGINT,
    hit_ratio_pct    NUMERIC
);

-- Database summary --------------------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.db_summary (
    snapshot_id      BIGINT REFERENCES perf_monitor.snapshots,
    captured_at      TIMESTAMPTZ,
    datname          TEXT,
    numbackends      INT,
    xact_commit      BIGINT,
    xact_rollback    BIGINT,
    rollback_pct     NUMERIC,
    cache_hit_pct    NUMERIC,
    deadlocks        BIGINT,
    temp_files       BIGINT,
    temp_bytes       BIGINT
);

-- Autovacuum activity -----------------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.autovacuum_activity (
    snapshot_id          BIGINT REFERENCES perf_monitor.snapshots,
    captured_at          TIMESTAMPTZ,
    pid                  INT,
    datname              TEXT,
    table_name           TEXT,
    phase                TEXT,
    heap_blks_vacuumed   BIGINT,
    num_dead_tuples      BIGINT
);

-- Streaming replication lag -----------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.replication_lag (
    snapshot_id      BIGINT REFERENCES perf_monitor.snapshots,
    captured_at      TIMESTAMPTZ,
    application_name TEXT,
    client_addr      INET,
    state            TEXT,
    write_lag        INTERVAL,
    flush_lag        INTERVAL,
    replay_lag       INTERVAL,
    sync_state       TEXT
);

-- Checkpoint / bgwriter stats ---------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.checkpoint_stats (
    snapshot_id            BIGINT REFERENCES perf_monitor.snapshots,
    captured_at            TIMESTAMPTZ,
    checkpoints_timed      BIGINT,
    checkpoints_req        BIGINT,
    forced_pct             NUMERIC,
    checkpoint_write_time  DOUBLE PRECISION,
    checkpoint_sync_time   DOUBLE PRECISION,
    buffers_checkpoint     BIGINT,
    buffers_clean          BIGINT,
    buffers_backend        BIGINT,
    buffers_backend_fsync  BIGINT,
    maxwritten_clean       BIGINT
);

-- Temp file pressure ------------------------------------------
CREATE TABLE IF NOT EXISTS perf_monitor.temp_pressure (
    snapshot_id       BIGINT REFERENCES perf_monitor.snapshots,
    captured_at       TIMESTAMPTZ,
    queryid           BIGINT,
    calls             BIGINT,
    temp_blks_written BIGINT,
    temp_written_mb   NUMERIC,
    mean_exec_ms      NUMERIC,
    query_snippet     TEXT
);


-- ============================================================
-- capture_snapshot() — call this during load test
-- ============================================================
-- Usage:
--   SELECT perf_monitor.capture_snapshot('baseline');
--   SELECT perf_monitor.capture_snapshot('peak_load', 'after 500 concurrent users');
-- ============================================================

CREATE OR REPLACE FUNCTION perf_monitor.capture_snapshot(
    p_label TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_snapshot_id BIGINT;
    v_now         TIMESTAMPTZ := now();
BEGIN
    INSERT INTO perf_monitor.snapshots(captured_at, label, notes)
    VALUES (v_now, p_label, p_notes)
    RETURNING snapshot_id INTO v_snapshot_id;

    -- Slow queries
    INSERT INTO perf_monitor.slow_queries
        (snapshot_id, captured_at, queryid, calls,
         total_exec_ms, mean_exec_ms, pct_total_time,
         temp_blks_written, rows_per_call, query_snippet)
    SELECT
        v_snapshot_id, v_now,
        queryid, calls,
        round(total_exec_time::numeric, 2),
        round(mean_exec_time::numeric, 2),
        round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2),
        temp_blks_written,
        round(rows::numeric / nullif(calls, 0), 2),
        left(query, 300)
    FROM pg_stat_statements
    WHERE calls > 5
    ORDER BY total_exec_time DESC
    LIMIT 50;

    -- Temp file pressure
    INSERT INTO perf_monitor.temp_pressure
        (snapshot_id, captured_at, queryid, calls,
         temp_blks_written, temp_written_mb, mean_exec_ms, query_snippet)
    SELECT
        v_snapshot_id, v_now,
        queryid, calls,
        temp_blks_written,
        round((temp_blks_written * 8192.0 / 1024 / 1024)::numeric, 2),
        round(mean_exec_time::numeric, 2),
        left(query, 300)
    FROM pg_stat_statements
    WHERE temp_blks_written > 0
    ORDER BY temp_blks_written DESC
    LIMIT 30;

    -- Connections
    INSERT INTO perf_monitor.connections
        (snapshot_id, captured_at, total, active, idle,
         idle_in_txn, idle_in_txn_aborted, waiting,
         max_connections, used_pct)
    SELECT
        v_snapshot_id, v_now,
        count(*),
        count(*) FILTER (WHERE state = 'active'),
        count(*) FILTER (WHERE state = 'idle'),
        count(*) FILTER (WHERE state = 'idle in transaction'),
        count(*) FILTER (WHERE state = 'idle in transaction (aborted)'),
        count(*) FILTER (WHERE wait_event IS NOT NULL),
        (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'),
        round(count(*)::numeric
            / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') * 100, 2)
    FROM pg_stat_activity
    WHERE pid <> pg_backend_pid();

    -- Lock waits
    INSERT INTO perf_monitor.lock_waits
        (snapshot_id, captured_at, blocked_pid, blocked_user,
         blocking_pids, wait_event_type, wait_event,
         blocked_duration, query_snippet)
    SELECT
        v_snapshot_id, v_now,
        pid,
        usename,
        pg_blocking_pids(pid),
        wait_event_type,
        wait_event,
        now() - query_start,
        left(query, 300)
    FROM pg_stat_activity
    WHERE cardinality(pg_blocking_pids(pid)) > 0;

    -- Wait events
    INSERT INTO perf_monitor.wait_events
        (snapshot_id, captured_at, wait_event_type, wait_event, session_count)
    SELECT
        v_snapshot_id, v_now,
        wait_event_type,
        wait_event,
        count(*)::int
    FROM pg_stat_activity
    WHERE wait_event IS NOT NULL
      AND pid <> pg_backend_pid()
    GROUP BY wait_event_type, wait_event;

    -- Table stats
    INSERT INTO perf_monitor.table_stats
        (snapshot_id, captured_at, schemaname, tablename,
         seq_scan, seq_tup_read, idx_scan,
         n_dead_tup, n_live_tup,
         heap_blks_hit, heap_blks_read, hit_ratio_pct)
    SELECT
        v_snapshot_id, v_now,
        t.schemaname, t.tablename,
        t.seq_scan, t.seq_tup_read, t.idx_scan,
        t.n_dead_tup, t.n_live_tup,
        io.heap_blks_hit, io.heap_blks_read,
        round(io.heap_blks_hit::numeric
            / nullif(io.heap_blks_read + io.heap_blks_hit, 0) * 100, 2)
    FROM pg_stat_user_tables t
    JOIN pg_statio_user_tables io USING (schemaname, tablename);

    -- DB summary
    INSERT INTO perf_monitor.db_summary
        (snapshot_id, captured_at, datname, numbackends,
         xact_commit, xact_rollback, rollback_pct,
         cache_hit_pct, deadlocks, temp_files, temp_bytes)
    SELECT
        v_snapshot_id, v_now,
        datname, numbackends,
        xact_commit, xact_rollback,
        round(xact_rollback::numeric / nullif(xact_commit + xact_rollback, 0) * 100, 2),
        round(blks_hit::numeric / nullif(blks_read + blks_hit, 0) * 100, 2),
        deadlocks, temp_files, temp_bytes
    FROM pg_stat_database
    WHERE datname NOT IN ('template0', 'template1');

    -- Autovacuum activity
    INSERT INTO perf_monitor.autovacuum_activity
        (snapshot_id, captured_at, pid, datname, table_name,
         phase, heap_blks_vacuumed, num_dead_tuples)
    SELECT
        v_snapshot_id, v_now,
        pid, datname, relid::regclass::text,
        phase, heap_blks_vacuumed, num_dead_tuples
    FROM pg_stat_progress_vacuum;

    -- Replication lag
    INSERT INTO perf_monitor.replication_lag
        (snapshot_id, captured_at, application_name, client_addr,
         state, write_lag, flush_lag, replay_lag, sync_state)
    SELECT
        v_snapshot_id, v_now,
        application_name, client_addr,
        state, write_lag, flush_lag, replay_lag, sync_state
    FROM pg_stat_replication;

    -- Checkpoint stats
    INSERT INTO perf_monitor.checkpoint_stats
        (snapshot_id, captured_at, checkpoints_timed, checkpoints_req,
         forced_pct, checkpoint_write_time, checkpoint_sync_time,
         buffers_checkpoint, buffers_clean,
         buffers_backend, buffers_backend_fsync, maxwritten_clean)
    SELECT
        v_snapshot_id, v_now,
        checkpoints_timed, checkpoints_req,
        round(checkpoints_req::numeric / nullif(checkpoints_timed + checkpoints_req, 0) * 100, 2),
        checkpoint_write_time, checkpoint_sync_time,
        buffers_checkpoint, buffers_clean,
        buffers_backend, buffers_backend_fsync, maxwritten_clean
    FROM pg_stat_bgwriter;

    RETURN v_snapshot_id;
END;
$$;


-- ============================================================
-- PART B · AD-HOC DIAGNOSTIC QUERIES
-- Run each section independently as needed
-- ============================================================


-- ============================================================
-- SECTION 01 · SLOW / EXPENSIVE QUERIES
-- What    : Top queries by total CPU time
-- Look for: mean_exec_ms > 100ms, pct_total_time > 10%
-- Action  : EXPLAIN ANALYZE the top offenders; consider index or query rewrite
-- ============================================================

SELECT
    round(total_exec_time::numeric, 2)                                      AS total_exec_ms,
    calls,
    round(mean_exec_time::numeric, 2)                                       AS mean_exec_ms,
    round(stddev_exec_time::numeric, 2)                                     AS stddev_exec_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS pct_total_time,
    rows,
    round(rows::numeric / nullif(calls, 0), 2)                             AS rows_per_call,
    shared_blks_hit,
    shared_blks_read,
    round(shared_blks_hit::numeric / nullif(shared_blks_hit + shared_blks_read, 0) * 100, 2) AS cache_hit_pct,
    left(query, 200)                                                        AS query_snippet
FROM pg_stat_statements
WHERE calls > 10
ORDER BY total_exec_time DESC
LIMIT 25;


-- ============================================================
-- SECTION 02 · TEMP FILE & work_mem PRESSURE
-- What    : Queries spilling to disk (work_mem too small)
-- Look for: temp_written_mb > 0 — every MB is a disk write
-- Action  : Increase work_mem for session / tune query plan
-- ============================================================

SELECT
    calls,
    round(mean_exec_time::numeric, 2)                                      AS mean_exec_ms,
    temp_blks_written,
    round((temp_blks_written * 8192.0 / 1024 / 1024)::numeric, 2)         AS temp_written_mb,
    temp_blks_read,
    round((temp_blks_read * 8192.0 / 1024 / 1024)::numeric, 2)            AS temp_read_mb,
    left(query, 200)                                                        AS query_snippet
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 20;


-- ============================================================
-- SECTION 03 · SEQUENTIAL SCAN HOTSPOTS
-- What    : Tables hit mostly with seq scans despite large size
-- Look for: seq_scan_pct > 50% on tables with n_live_tup > 10k
-- Action  : Add index; or investigate if full-scan is intentional
-- ============================================================

SELECT
    schemaname,
    tablename,
    seq_scan,
    seq_tup_read,
    idx_scan,
    round(seq_scan::numeric / nullif(seq_scan + idx_scan, 0) * 100, 2)    AS seq_scan_pct,
    n_live_tup,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size
FROM pg_stat_user_tables
WHERE seq_scan > 0
  AND n_live_tup > 10000
ORDER BY seq_scan DESC
LIMIT 20;


-- ============================================================
-- SECTION 04 · N+1 PATTERNS (HIGH-FREQUENCY FAST QUERIES)
-- What    : Queries called thousands of times, cheap individually
-- Look for: calls > 10000 and mean_exec_ms < 5
-- Action  : Batch queries; add caching layer; review ORM usage
-- ============================================================

SELECT
    calls,
    round(mean_exec_time::numeric, 4)                                      AS mean_exec_ms,
    round(total_exec_time::numeric, 2)                                     AS total_exec_ms,
    round(rows::numeric / nullif(calls, 0), 2)                             AS rows_per_call,
    left(query, 200)                                                        AS query_snippet
FROM pg_stat_statements
WHERE calls > 10000
  AND mean_exec_time < 10
ORDER BY calls DESC
LIMIT 20;


-- ============================================================
-- SECTION 05 · JIT COMPILATION OVERHEAD
-- What    : Queries where JIT cost may exceed benefit
-- Look for: total_jit_ms > mean_exec_ms (JIT costs more than it saves)
-- Action  : SET jit = off for session or raise jit_above_cost
-- ============================================================

SELECT
    calls,
    round(mean_exec_time::numeric, 2)                                      AS mean_exec_ms,
    jit_functions,
    round(jit_generation_time::numeric, 2)                                 AS jit_gen_ms,
    round(jit_inlining_time::numeric, 2)                                   AS jit_inline_ms,
    round(jit_optimization_time::numeric, 2)                               AS jit_opt_ms,
    round(jit_emission_time::numeric, 2)                                   AS jit_emit_ms,
    round((jit_generation_time + jit_inlining_time
           + jit_optimization_time + jit_emission_time)::numeric, 2)      AS total_jit_ms,
    left(query, 200)                                                        AS query_snippet
FROM pg_stat_statements
WHERE jit_functions > 0
ORDER BY jit_generation_time + jit_inlining_time + jit_optimization_time + jit_emission_time DESC
LIMIT 15;


-- ============================================================
-- SECTION 06 · UNUSED INDEXES
-- What    : Indexes never used by any query scan
-- Look for: idx_scan = 0 on non-primary, non-unique indexes
-- Action  : DROP after verifying (check pg_stat_reset date first)
-- ============================================================

SELECT
    s.schemaname,
    s.tablename,
    s.indexname,
    pg_size_pretty(pg_relation_size(s.indexrelid))                        AS index_size,
    s.idx_scan,
    s.idx_tup_read,
    s.idx_tup_fetch,
    pg_stat_get_last_analyze_time(c.oid)                                  AS last_analyze
FROM pg_stat_user_indexes s
JOIN pg_index i USING (indexrelid)
JOIN pg_class c ON c.oid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisprimary
  AND NOT i.indisunique
  AND pg_relation_size(s.indexrelid) > 0
ORDER BY pg_relation_size(s.indexrelid) DESC;


-- ============================================================
-- SECTION 07 · DUPLICATE / REDUNDANT INDEXES
-- What    : Multiple indexes covering the same leading columns
-- Look for: Same table + indkey combination appearing > 1 time
-- Action  : Keep the most specific; drop the rest
-- ============================================================

SELECT
    indrelid::regclass                                                     AS table_name,
    array_agg(indexrelid::regclass ORDER BY indexrelid)                   AS duplicate_indexes,
    array_agg(pg_size_pretty(pg_relation_size(indexrelid)) ORDER BY indexrelid) AS sizes,
    indkey::text                                                           AS index_columns
FROM pg_index
GROUP BY indrelid, indkey
HAVING count(*) > 1
ORDER BY indrelid::regclass::text;


-- ============================================================
-- SECTION 08 · INVALID INDEXES
-- What    : Indexes left in invalid state (e.g. failed CONCURRENTLY)
-- Look for: indisvalid = false
-- Action  : DROP and recreate; they waste space and are never used
-- ============================================================

SELECT
    n.nspname                                                              AS schemaname,
    c.relname                                                              AS tablename,
    i.relname                                                              AS indexname,
    pg_size_pretty(pg_relation_size(i.oid))                               AS wasted_size
FROM pg_index x
JOIN pg_class c ON c.oid = x.indrelid
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT x.indisvalid
  AND n.nspname NOT IN ('pg_catalog', 'information_schema');


-- ============================================================
-- SECTION 09 · MISSING FOREIGN KEY INDEXES
-- What    : FK columns with no supporting index (expensive joins + cascades)
-- Look for: Any row — these are almost always worth indexing
-- Action  : CREATE INDEX ON table(fk_column);
-- ============================================================

SELECT
    c.conrelid::regclass                                                   AS table_name,
    c.conname                                                              AS constraint_name,
    string_agg(a.attname, ', ' ORDER BY x.n)                             AS fk_columns
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
ORDER BY table_name;


-- ============================================================
-- SECTION 10 · INDEX BLOAT (ESTIMATION)
-- What    : Indexes with high free-space fragmentation
-- Look for: bloat_ratio > 30% on large indexes
-- Action  : REINDEX CONCURRENTLY to reclaim space
-- Note    : For precise results install pgstattuple and use
--           pgstattuple(indexname).avg_leaf_density
-- ============================================================

WITH index_info AS (
    SELECT
        n.nspname                          AS schemaname,
        ct.relname                         AS tablename,
        ci.relname                         AS indexname,
        ci.oid                             AS indexrelid,
        pg_relation_size(ci.oid)           AS index_bytes,
        ci.relpages                        AS actual_pages,
        -- estimated minimal pages needed
        ceil(ci.reltuples *
             (6  -- index tuple overhead estimate
              + 8 -- item pointer
             ) / (current_setting('block_size')::int * 0.8)
        )                                  AS estimated_min_pages
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
    round((1 - estimated_min_pages / nullif(actual_pages, 0)) * 100, 2)  AS bloat_pct_estimate
FROM index_info
WHERE index_bytes > 1024 * 1024   -- > 1 MB
  AND actual_pages > estimated_min_pages
ORDER BY index_bytes DESC
LIMIT 20;


-- ============================================================
-- SECTION 11 · TABLE BLOAT (ESTIMATION)
-- What    : Tables with large amounts of dead/unreclaimable space
-- Look for: bloat_mb > 100 or bloat_pct > 20%
-- Action  : VACUUM FULL (lock!) or pg_repack (online)
-- ============================================================

WITH constants AS (
    SELECT current_setting('block_size')::int AS bs,
           23                                 AS hdr,
           8                                  AS ma
),
per_table AS (
    SELECT
        schemaname,
        tablename,
        (datawidth + hdr + ma
          - CASE WHEN hdr % ma = 0 THEN ma ELSE hdr % ma END
        )                                                                  AS row_data_width,
        relpages,
        reltuples,
        bs
    FROM (
        SELECT
            ns.nspname                                                     AS schemaname,
            tbl.relname                                                    AS tablename,
            tbl.relpages,
            tbl.reltuples,
            bs,
            hdr,
            ma,
            sum((1 - s.null_frac) * s.avg_width)::int                    AS datawidth
        FROM pg_class tbl
        JOIN pg_namespace ns    ON ns.oid = tbl.relnamespace
        JOIN pg_attribute att   ON att.attrelid = tbl.oid AND att.attnum > 0 AND NOT att.attisdropped
        JOIN pg_stats s         ON s.schemaname = ns.nspname
                                AND s.tablename  = tbl.relname
                                AND s.attname    = att.attname
        CROSS JOIN constants
        WHERE tbl.relkind = 'r'
          AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
        GROUP BY ns.nspname, tbl.relname, tbl.relpages, tbl.reltuples, bs, hdr, ma
    ) sub
)
SELECT
    schemaname,
    tablename,
    relpages                                                               AS actual_pages,
    round(reltuples)                                                       AS est_row_count,
    pg_size_pretty((relpages * bs)::bigint)                               AS total_size,
    pg_size_pretty(
        greatest(0, relpages - ceil(reltuples * row_data_width / bs))::bigint * bs
    )                                                                      AS bloat_size_estimate,
    round(
        greatest(0, 1 - ceil(reltuples * row_data_width / bs) / nullif(relpages, 0)) * 100,
        2
    )                                                                      AS bloat_pct_estimate
FROM per_table
WHERE relpages > 10
ORDER BY greatest(0, relpages - ceil(reltuples * row_data_width / bs)) DESC
LIMIT 20;


-- ============================================================
-- SECTION 12 · TOAST TABLE BLOAT
-- What    : Oversized TOAST tables (large text/jsonb/bytea columns)
-- Look for: toast_size >> table_size
-- Action  : VACUUM table; check if large values can be compressed/chunked
-- ============================================================

SELECT
    n.nspname                                                              AS schemaname,
    c.relname                                                              AS tablename,
    pg_size_pretty(pg_relation_size(c.oid))                               AS table_size,
    pg_size_pretty(pg_relation_size(t.oid))                               AS toast_size,
    round(pg_relation_size(t.oid)::numeric
        / nullif(pg_relation_size(c.oid), 0) * 100, 2)                   AS toast_to_table_pct
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_class t     ON t.oid = c.reltoastrelid
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND pg_relation_size(t.oid) > 1024 * 1024   -- TOAST > 1 MB
ORDER BY pg_relation_size(t.oid) DESC
LIMIT 20;


-- ============================================================
-- SECTION 13 · TABLE & INDEX SIZE RANKING
-- What    : Largest objects by total, heap, index, and TOAST size
-- Look for: Unexpected growth; index_size >> table_size
-- Action  : Investigate large objects; review index necessity
-- ============================================================

SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename))       AS heap_size,
    pg_size_pretty(pg_indexes_size(schemaname || '.' || tablename))        AS indexes_size,
    pg_size_pretty(
        pg_total_relation_size(schemaname || '.' || tablename)
        - pg_relation_size(schemaname || '.' || tablename)
        - pg_indexes_size(schemaname || '.' || tablename)
    )                                                                      AS toast_size,
    pg_total_relation_size(schemaname || '.' || tablename)                 AS total_bytes
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY total_bytes DESC
LIMIT 30;


-- ============================================================
-- SECTION 14 · TABLE ACCESS PATTERNS
-- What    : Heap vs index fetch ratio per table
-- Look for: High seq_tup_read with low idx_tup_fetch (missing index)
--           High n_tup_upd with high n_dead_tup (vacuum lag)
-- Action  : Add index for seq scan tables; run VACUUM ANALYZE for high dead_pct
-- ============================================================

SELECT
    schemaname,
    tablename,
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
    round(n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 2) AS dead_pct
FROM pg_stat_user_tables
ORDER BY seq_tup_read + idx_tup_fetch DESC
LIMIT 25;


-- ============================================================
-- SECTION 15 · AUTOVACUUM WORKER ACTIVITY (RIGHT NOW)
-- What    : Currently running vacuum workers and their progress
-- Look for: Stuck workers; index_vacuum_count = 0 on large tables
-- ============================================================

SELECT
    pid,
    datname,
    relid::regclass                                                        AS table_name,
    phase,
    heap_blks_total,
    heap_blks_scanned,
    heap_blks_vacuumed,
    round(heap_blks_vacuumed::numeric / nullif(heap_blks_total, 0) * 100, 2) AS pct_done,
    index_vacuum_count,
    max_dead_tuples,
    num_dead_tuples
FROM pg_stat_progress_vacuum;


-- ============================================================
-- SECTION 16 · DEAD TUPLE URGENCY (VACUUM BACKLOG)
-- What    : Tables accumulating dead tuples faster than vacuum clears them
-- Look for: dead_pct > 10%; last_autovacuum = NULL or days ago
-- Action  : VACUUM ANALYZE tablename; or tune autovacuum_vacuum_scale_factor
-- ============================================================

SELECT
    schemaname,
    tablename,
    n_dead_tup,
    n_live_tup,
    round(n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 2) AS dead_pct,
    n_mod_since_analyze,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename))      AS table_size
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 25;


-- ============================================================
-- SECTION 17 · STALE STATISTICS (ANALYZE OVERDUE)
-- What    : Tables with many modifications since last ANALYZE
-- Look for: n_mod_since_analyze high relative to n_live_tup
-- Action  : ANALYZE tablename; reduce autovacuum_analyze_scale_factor
-- ============================================================

SELECT
    schemaname,
    tablename,
    n_live_tup,
    n_mod_since_analyze,
    round(n_mod_since_analyze::numeric / nullif(n_live_tup, 0) * 100, 2) AS mod_pct,
    last_analyze,
    last_autoanalyze,
    now() - greatest(last_analyze, last_autoanalyze)                      AS time_since_analyze
FROM pg_stat_user_tables
WHERE n_live_tup > 1000
ORDER BY n_mod_since_analyze DESC
LIMIT 20;


-- ============================================================
-- SECTION 18 · LONG-RUNNING TRANSACTIONS
-- What    : Open transactions blocking vacuum and holding locks
-- Look for: xact_duration > 5 minutes
-- Action  : SELECT pg_terminate_backend(pid) after investigation
-- ============================================================

SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    now() - xact_start                                                     AS xact_duration,
    now() - query_start                                                    AS query_duration,
    left(query, 200)                                                        AS current_query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes'
  AND pid <> pg_backend_pid()
ORDER BY xact_start ASC;


-- ============================================================
-- SECTION 19 · CONNECTION SATURATION
-- What    : Current vs max_connections; headroom remaining
-- Look for: used_pct > 80% — approaching connection limit
-- Action  : Add PgBouncer / connection pooler; review idle connections
-- ============================================================

SELECT
    count(*)                                                               AS total,
    count(*) FILTER (WHERE state = 'active')                              AS active,
    count(*) FILTER (WHERE state = 'idle')                                AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction')                 AS idle_in_txn,
    count(*) FILTER (WHERE state = 'idle in transaction (aborted)')       AS idle_in_txn_aborted,
    count(*) FILTER (WHERE wait_event IS NOT NULL AND state = 'active')   AS waiting,
    max_conn.setting::int                                                  AS max_connections,
    round(count(*)::numeric / max_conn.setting::int * 100, 2)            AS used_pct,
    max_conn.setting::int - count(*)                                       AS free_slots
FROM pg_stat_activity, pg_settings max_conn
WHERE max_conn.name = 'max_connections'
  AND pg_stat_activity.pid <> pg_backend_pid()
GROUP BY max_conn.setting;

-- Per application breakdown
SELECT
    application_name,
    state,
    count(*) AS connections
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY application_name, state
ORDER BY count(*) DESC
LIMIT 20;


-- ============================================================
-- SECTION 20 · IDLE-IN-TRANSACTION CONNECTIONS
-- What    : Sessions sitting idle inside an open transaction
-- Look for: idle_duration > 30s — these block vacuum and hold locks
-- Action  : Fix application to commit/rollback promptly; set idle_in_transaction_session_timeout
-- ============================================================

SELECT
    pid,
    usename,
    application_name,
    client_addr,
    now() - state_change                                                   AS idle_duration,
    now() - xact_start                                                     AS txn_open_duration,
    left(query, 200)                                                        AS last_query
FROM pg_stat_activity
WHERE state IN ('idle in transaction', 'idle in transaction (aborted)')
ORDER BY state_change ASC;


-- ============================================================
-- SECTION 21 · LOCK WAIT TREE (BLOCKING CHAINS)
-- What    : Full chain of who is blocking whom
-- Look for: Any row — every lock wait degrades throughput
-- Action  : Identify root blocker (blocking_pids = '{}') and investigate
-- ============================================================

SELECT
    pid                                                                    AS blocked_pid,
    usename                                                                AS blocked_user,
    pg_blocking_pids(pid)                                                  AS blocking_pids,
    cardinality(pg_blocking_pids(pid))                                     AS blocking_depth,
    wait_event_type,
    wait_event,
    state,
    now() - query_start                                                    AS waiting_duration,
    left(query, 200)                                                        AS blocked_query
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0
ORDER BY waiting_duration DESC;

-- Detailed lock mode breakdown
SELECT
    l.pid,
    l.locktype,
    l.relation::regclass                                                   AS locked_object,
    l.mode,
    l.granted,
    a.usename,
    a.state,
    left(a.query, 150)                                                     AS query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE NOT l.granted
   OR l.pid IN (
       SELECT unnest(pg_blocking_pids(pid))
       FROM pg_stat_activity
       WHERE cardinality(pg_blocking_pids(pid)) > 0
   )
ORDER BY l.pid;


-- ============================================================
-- SECTION 22 · WAIT EVENTS BREAKDOWN
-- What    : What all sessions are currently waiting on
-- Look for: Lock, LWLock, IO waits > a few sessions
-- Action  : Cross-reference with lock tree; investigate I/O if DataFileRead dominates
-- ============================================================

SELECT
    wait_event_type,
    wait_event,
    count(*)                                                               AS sessions,
    array_agg(pid ORDER BY pid)                                           AS pids
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
  AND pid <> pg_backend_pid()
GROUP BY wait_event_type, wait_event
ORDER BY sessions DESC;


-- ============================================================
-- SECTION 23 · STREAMING REPLICATION LAG
-- What    : Per-standby write, flush, replay lag
-- Look for: replay_lag > 30s; flush_lag > 10s
-- Action  : Investigate standby I/O; check network throughput
-- ============================================================

SELECT
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
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))     AS unsent_wal
FROM pg_stat_replication
ORDER BY replay_lag DESC NULLS LAST;


-- ============================================================
-- SECTION 24 · LOGICAL REPLICATION SLOT LAG
-- What    : WAL accumulating for logical replication consumers
-- Look for: lag_mb > 500 — risk of disk exhaustion
-- Action  : Check consumer health; drop slot if consumer is gone
-- ============================================================

SELECT
    slot_name,
    plugin,
    database,
    active,
    active_pid,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
    )                                                                      AS consumer_lag_size,
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)           AS consumer_lag_bytes
FROM pg_replication_slots
WHERE slot_type = 'logical'
ORDER BY consumer_lag_bytes DESC NULLS LAST;


-- ============================================================
-- SECTION 25 · REPLICATION SLOT WAL RETENTION
-- What    : Total WAL held on disk by ALL slots (streaming + logical)
-- Look for: wal_retained > your pg_wal partition free space * 50%
-- Action  : Drop inactive slots; advance or drop lagging ones
-- ============================================================

SELECT
    slot_name,
    slot_type,
    active,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    )                                                                      AS wal_retained,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)                   AS wal_retained_bytes
FROM pg_replication_slots
ORDER BY wal_retained_bytes DESC NULLS LAST;


-- ============================================================
-- SECTION 26 · TRANSACTION ID (XID) WRAPAROUND RISK
-- What    : Distance from XID exhaustion (hard limit: 2 billion)
-- Look for: xid_age > 1.5 billion (emergency VACUUM needed)
--           pct_used > 70% — start planning maintenance
-- Action  : VACUUM FREEZE on oldest tables; reduce autovacuum_freeze_max_age
-- ============================================================

-- Database level
SELECT
    datname,
    age(datfrozenxid)                                                      AS xid_age,
    2147483647 - age(datfrozenxid)                                        AS xid_remaining,
    round(age(datfrozenxid)::numeric / 2147483647 * 100, 2)              AS pct_used
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Table level (top 20 oldest)
SELECT
    n.nspname                                                              AS schemaname,
    c.relname                                                              AS tablename,
    age(c.relfrozenxid)                                                    AS xid_age,
    round(age(c.relfrozenxid)::numeric / 2147483647 * 100, 2)            AS pct_used,
    pg_size_pretty(pg_relation_size(c.oid))                               AS table_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 20;


-- ============================================================
-- SECTION 27 · MULTIXACT ID (MXID) WRAPAROUND RISK
-- What    : Distance from MultiXact exhaustion
-- Look for: mxid_age > 1 billion — tables need VACUUM FREEZE
-- ============================================================

SELECT
    datname,
    mxid_age(datminmxid)                                                   AS mxid_age,
    2147483647 - mxid_age(datminmxid)                                     AS mxid_remaining,
    round(mxid_age(datminmxid)::numeric / 2147483647 * 100, 2)           AS pct_used
FROM pg_database
ORDER BY mxid_age(datminmxid) DESC;


-- ============================================================
-- SECTION 28 · SEQUENCE EXHAUSTION RISK
-- What    : Sequences approaching their max value (integer overflow)
-- Look for: pct_used > 80% on bigint; any value on int/smallint
-- Action  : ALTER SEQUENCE ... MAXVALUE or change column type to bigint
-- ============================================================

SELECT
    schemaname,
    sequencename,
    data_type,
    last_value,
    min_value,
    max_value,
    increment_by,
    cycle,
    round((last_value - min_value)::numeric / nullif(max_value - min_value, 0) * 100, 2) AS pct_used,
    (max_value - last_value) / nullif(increment_by, 0)                    AS values_remaining
FROM pg_sequences
WHERE NOT cycle
  AND last_value IS NOT NULL
ORDER BY pct_used DESC NULLS LAST
LIMIT 20;


-- ============================================================
-- SECTION 29 · KEY GUC SETTINGS REVIEW
-- What    : Critical configuration vs source (default/config/session)
-- Look for: source = 'default' on memory settings (often too small)
-- ============================================================

SELECT
    name,
    setting,
    unit,
    source,
    short_desc
FROM pg_settings
WHERE name IN (
    -- Memory
    'shared_buffers', 'work_mem', 'maintenance_work_mem',
    'effective_cache_size', 'temp_buffers',
    -- Checkpoints & WAL
    'checkpoint_timeout', 'checkpoint_completion_target',
    'max_wal_size', 'min_wal_size', 'wal_level', 'wal_compression',
    -- Autovacuum
    'autovacuum', 'autovacuum_max_workers',
    'autovacuum_vacuum_cost_delay', 'autovacuum_vacuum_scale_factor',
    'autovacuum_analyze_scale_factor', 'autovacuum_freeze_max_age',
    -- Connections
    'max_connections', 'superuser_reserved_connections',
    'idle_in_transaction_session_timeout', 'statement_timeout',
    -- Parallelism
    'max_parallel_workers_per_gather', 'max_worker_processes',
    'max_parallel_workers',
    -- I/O
    'random_page_cost', 'seq_page_cost', 'effective_io_concurrency',
    -- JIT
    'enable_jit', 'jit_above_cost', 'jit_optimize_above_cost',
    -- Logging
    'log_min_duration_statement', 'log_lock_waits',
    'deadlock_timeout', 'log_temp_files',
    -- Lock
    'lock_timeout', 'deadlock_timeout'
)
ORDER BY
    CASE
        WHEN name LIKE '%buffer%' OR name LIKE '%mem%' THEN 1
        WHEN name LIKE '%checkpoint%' OR name LIKE '%wal%' THEN 2
        WHEN name LIKE '%autovacuum%' THEN 3
        WHEN name LIKE '%connection%' OR name LIKE '%timeout%' THEN 4
        ELSE 5
    END,
    name;


-- ============================================================
-- SECTION 30 · BUFFER CACHE HIT RATIO
-- What    : How often reads are served from shared_buffers vs disk
-- Look for: hit_ratio_pct < 95% on hot tables
-- Action  : Increase shared_buffers; check for seq scan storms
-- ============================================================

-- Per table
SELECT
    schemaname,
    tablename,
    heap_blks_read,
    heap_blks_hit,
    round(heap_blks_hit::numeric / nullif(heap_blks_read + heap_blks_hit, 0) * 100, 2) AS hit_ratio_pct,
    idx_blks_read,
    idx_blks_hit,
    round(idx_blks_hit::numeric / nullif(idx_blks_read + idx_blks_hit, 0) * 100, 2) AS idx_hit_ratio_pct
FROM pg_statio_user_tables
WHERE heap_blks_read + heap_blks_hit > 1000
ORDER BY heap_blks_read DESC
LIMIT 20;

-- Global database hit ratio
SELECT
    sum(blks_hit) AS total_hits,
    sum(blks_read) AS total_reads,
    round(sum(blks_hit)::numeric / nullif(sum(blks_hit) + sum(blks_read), 0) * 100, 2) AS global_hit_ratio_pct
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1');


-- ============================================================
-- SECTION 31 · CHECKPOINT & WAL PRESSURE
-- What    : Whether checkpoints are being forced (too frequent)
--           and backend writes to WAL (bypassing bgwriter)
-- Look for: forced_pct > 10%; buffers_backend_fsync > 0 is critical
-- Action  : Increase max_wal_size; tune checkpoint_completion_target = 0.9
-- ============================================================

SELECT
    checkpoints_timed,
    checkpoints_req,
    round(checkpoints_req::numeric / nullif(checkpoints_timed + checkpoints_req, 0) * 100, 2) AS forced_pct,
    round(checkpoint_write_time / 1000, 2)                                AS write_time_sec,
    round(checkpoint_sync_time / 1000, 2)                                 AS sync_time_sec,
    buffers_checkpoint,
    buffers_clean,
    maxwritten_clean,
    buffers_backend,
    buffers_backend_fsync,          -- > 0 means backends are fsyncing, very bad
    buffers_alloc,
    now() - stats_reset                                                    AS stats_age
FROM pg_stat_bgwriter;


-- ============================================================
-- SECTION 32 · DATABASE-LEVEL SUMMARY
-- What    : Per-database throughput, cache, deadlocks, temp usage
-- Look for: rollback_pct > 5%; deadlocks > 0; cache_hit_pct < 95%
-- Action  : Investigate rollback sources; add deadlock_timeout logging; tune shared_buffers
-- ============================================================

SELECT
    datname,
    numbackends                                                            AS active_backends,
    xact_commit,
    xact_rollback,
    round(xact_rollback::numeric / nullif(xact_commit + xact_rollback, 0) * 100, 2) AS rollback_pct,
    blks_read,
    blks_hit,
    round(blks_hit::numeric / nullif(blks_read + blks_hit, 0) * 100, 2) AS cache_hit_pct,
    tup_returned,
    tup_fetched,
    tup_inserted,
    tup_updated,
    tup_deleted,
    conflicts,
    temp_files,
    pg_size_pretty(temp_bytes)                                            AS temp_usage,
    deadlocks,
    pg_size_pretty(pg_database_size(datname))                            AS db_size,
    now() - stats_reset                                                    AS stats_age
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY numbackends DESC;


-- ============================================================
-- SECTION 33 · WAL GENERATION RATE
-- What    : WAL (Write-Ahead Log) generation volume and rate since stats reset
-- Look for: High wal_mb_per_hour (e.g. > 1000 MB/hr) indicating write intensity;
--           high fpi_pct (> 20%) indicating potential checkpoint pressure
-- Action  : Enable wal_compression; tune max_wal_size and checkpoint_timeout;
--           investigate write-heavy queries or large updates
-- Requires: PostgreSQL 14+
-- ============================================================

SELECT
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
FROM pg_stat_wal;


-- ============================================================
-- SECTION 34 · PARTITIONED TABLE HEALTH
-- What    : Partitioned tables, partition counts, and total sizes
-- Look for: partition_count > 100 (high planning overhead);
--           partition_count = 0 (inserts will fail unless default partition exists)
-- Action  : Merge old partitions or partition by larger range (e.g. monthly);
--           create missing partitions if partition_count = 0
-- ============================================================

SELECT
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
ORDER BY partition_count DESC;


-- ============================================================
-- SECTION 35 · OPEN PREPARED TRANSACTIONS
-- What    : Uncommitted prepared transactions (2PC/two-phase commit)
-- Look for: Any row older than 5 minutes (blocks vacuum, holds locks)
-- Action  : Run COMMIT PREPARED '<gid>'; or ROLLBACK PREPARED '<gid>';
-- ============================================================

SELECT
    gid,
    prepared,
    owner,
    database,
    now() - prepared                                                          AS age,
    transaction::text                                                          AS xid
FROM pg_prepared_xacts
ORDER BY prepared ASC;


-- ============================================================
-- SECTION 36 · I/O STATS BY BACKEND (pg_stat_io)
-- What    : I/O statistics broken down by backend type, target object, and context
-- Look for: High evictions (shared_buffers size too small); high temp relation
--           reads/writes (queries spilling to disk/work_mem too small)
-- Action  : Increase work_mem if temp relation I/O is high; increase shared_buffers
--           if evictions are high; tune checkpointer if writes dominate backends
-- Requires: PostgreSQL 16+, track_io_timing = on (optional for timings)
-- ============================================================

SELECT
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
ORDER BY reads + writes DESC;


-- ============================================================
-- PART C · TREND & DELTA ANALYSIS
-- (Requires PART A logging schema populated with snapshots)
-- ============================================================


-- List all snapshots
SELECT snapshot_id, captured_at, label, notes
FROM perf_monitor.snapshots
ORDER BY captured_at;


-- Connection trend over all snapshots
SELECT
    s.captured_at,
    s.label,
    c.total,
    c.active,
    c.idle_in_txn,
    c.used_pct
FROM perf_monitor.connections c
JOIN perf_monitor.snapshots s USING (snapshot_id)
ORDER BY s.captured_at;


-- Delta between any two snapshots (change snapshot_id values as needed)
-- Replace :snap_a and :snap_b with actual snapshot IDs
WITH a AS (SELECT * FROM perf_monitor.connections WHERE snapshot_id = :snap_a),
     b AS (SELECT * FROM perf_monitor.connections WHERE snapshot_id = :snap_b)
SELECT
    b.captured_at                                                          AS snap_b_time,
    b.total         - a.total                                              AS total_delta,
    b.active        - a.active                                             AS active_delta,
    b.idle_in_txn   - a.idle_in_txn                                       AS idle_txn_delta,
    b.used_pct      - a.used_pct                                           AS used_pct_delta
FROM a, b;


-- Lock wait count over time (spikes = contention events)
SELECT
    s.captured_at,
    s.label,
    count(l.blocked_pid)                                                   AS lock_waits
FROM perf_monitor.snapshots s
LEFT JOIN perf_monitor.lock_waits l USING (snapshot_id)
GROUP BY s.snapshot_id, s.captured_at, s.label
ORDER BY s.captured_at;


-- Top wait events during the test (aggregate across all snapshots)
SELECT
    wait_event_type,
    wait_event,
    sum(session_count)                                                     AS total_waits,
    round(avg(session_count), 2)                                           AS avg_per_snapshot
FROM perf_monitor.wait_events w
JOIN perf_monitor.snapshots s USING (snapshot_id)
GROUP BY wait_event_type, wait_event
ORDER BY total_waits DESC
LIMIT 20;


-- Dead tuple growth between baseline and peak
WITH snap_a AS (
    SELECT s.snapshot_id FROM perf_monitor.snapshots s WHERE s.label = 'baseline' LIMIT 1
),
snap_b AS (
    SELECT s.snapshot_id FROM perf_monitor.snapshots s WHERE s.label = 'peak' LIMIT 1
)
SELECT
    a.schemaname,
    a.tablename,
    a.n_dead_tup                                                           AS dead_at_baseline,
    b.n_dead_tup                                                           AS dead_at_peak,
    b.n_dead_tup - a.n_dead_tup                                           AS dead_growth,
    b.seq_scan   - a.seq_scan                                              AS seq_scan_delta,
    b.idx_scan   - a.idx_scan                                              AS idx_scan_delta
FROM perf_monitor.table_stats a
JOIN perf_monitor.table_stats b ON b.schemaname = a.schemaname AND b.tablename = a.tablename
WHERE a.snapshot_id = (SELECT snapshot_id FROM snap_a)
  AND b.snapshot_id = (SELECT snapshot_id FROM snap_b)
ORDER BY dead_growth DESC
LIMIT 20;


-- Cache hit ratio trend
SELECT
    s.captured_at,
    s.label,
    round(avg(t.hit_ratio_pct), 2)                                        AS avg_cache_hit_pct,
    min(t.hit_ratio_pct)                                                   AS min_cache_hit_pct
FROM perf_monitor.table_stats t
JOIN perf_monitor.snapshots s USING (snapshot_id)
WHERE t.heap_blks_read + t.heap_blks_hit > 0
GROUP BY s.snapshot_id, s.captured_at, s.label
ORDER BY s.captured_at;


-- Deadlock trend
SELECT
    s.captured_at,
    s.label,
    sum(d.deadlocks)                                                       AS deadlocks
FROM perf_monitor.db_summary d
JOIN perf_monitor.snapshots s USING (snapshot_id)
GROUP BY s.snapshot_id, s.captured_at, s.label
ORDER BY s.captured_at;


-- Checkpoint pressure trend
SELECT
    s.captured_at,
    s.label,
    c.forced_pct,
    c.buffers_backend,
    c.buffers_backend_fsync,
    c.maxwritten_clean
FROM perf_monitor.checkpoint_stats c
JOIN perf_monitor.snapshots s USING (snapshot_id)
ORDER BY s.captured_at;


-- Temp file pressure trend (total spill to disk across all queries)
SELECT
    s.captured_at,
    s.label,
    sum(t.temp_blks_written)                                              AS total_temp_blks,
    round(sum(t.temp_written_mb), 2)                                      AS total_temp_mb
FROM perf_monitor.temp_pressure t
JOIN perf_monitor.snapshots s USING (snapshot_id)
GROUP BY s.snapshot_id, s.captured_at, s.label
ORDER BY s.captured_at;


-- ============================================================
-- LOAD TEST WORKFLOW EXAMPLE
-- ============================================================
--
-- 1. Setup (run once):
--      \i postgres_perf_diagnostics.sql   -- creates schema + function
--      SELECT pg_stat_statements_reset(); -- optional: clear history
--
-- 2. Capture baseline:
--      SELECT perf_monitor.capture_snapshot('baseline', 'before any load');
--
-- 3. Start your load test tool (k6, pgbench, JMeter, Locust...)
--
-- 4. Capture at intervals (e.g. every 60s via psql \watch or a script):
--      SELECT perf_monitor.capture_snapshot('ramp_up');
--      SELECT perf_monitor.capture_snapshot('peak');
--      SELECT perf_monitor.capture_snapshot('cooldown');
--
-- 5. Analyse:
--      -- Connection saturation trend
--      SELECT captured_at, label, used_pct FROM perf_monitor.connections
--      JOIN perf_monitor.snapshots USING (snapshot_id) ORDER BY captured_at;
--
--      -- Most frequent lock waits during test
--      SELECT wait_event, sum(session_count) FROM perf_monitor.wait_events
--      JOIN perf_monitor.snapshots USING (snapshot_id)
--      GROUP BY wait_event ORDER BY 2 DESC;
--
-- 6. Automate capture every N seconds using psql \watch:
--      \t on
--      SELECT perf_monitor.capture_snapshot('load_test'); \watch 30
--
-- 7. Teardown (after analysis):
--      DROP SCHEMA perf_monitor CASCADE;
-- ============================================================
