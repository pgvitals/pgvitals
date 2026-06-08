-- ============================================================
-- pgvitals · Monitoring Schema
-- ============================================================
-- Creates the perf_monitor schema and all snapshot tables.
-- Run once before a load test. Drop with:
--   DROP SCHEMA perf_monitor CASCADE;
-- ============================================================

CREATE SCHEMA IF NOT EXISTS perf_monitor;

-- Snapshot registry
CREATE TABLE IF NOT EXISTS perf_monitor.snapshots (
    snapshot_id  BIGSERIAL    PRIMARY KEY,
    captured_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    label        TEXT,        -- 'baseline','ramp_up','peak','cooldown'
    notes        TEXT
);

-- 01 Slow queries
CREATE TABLE IF NOT EXISTS perf_monitor.slow_queries (
    snapshot_id       BIGINT REFERENCES perf_monitor.snapshots,
    captured_at       TIMESTAMPTZ,
    queryid           BIGINT,
    calls             BIGINT,
    total_exec_ms     NUMERIC,
    mean_exec_ms      NUMERIC,
    pct_total_time    NUMERIC,
    temp_blks_written BIGINT,
    rows_per_call     NUMERIC,
    query_snippet     TEXT
);

-- 02 Temp file pressure
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

-- 19 Connection saturation
CREATE TABLE IF NOT EXISTS perf_monitor.connections (
    snapshot_id          BIGINT REFERENCES perf_monitor.snapshots,
    captured_at          TIMESTAMPTZ,
    total                INT,
    active               INT,
    idle                 INT,
    idle_in_txn          INT,
    idle_in_txn_aborted  INT,
    waiting              INT,
    max_connections      INT,
    used_pct             NUMERIC
);

-- 21 Lock waits
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

-- 22 Wait events
CREATE TABLE IF NOT EXISTS perf_monitor.wait_events (
    snapshot_id      BIGINT REFERENCES perf_monitor.snapshots,
    captured_at      TIMESTAMPTZ,
    wait_event_type  TEXT,
    wait_event       TEXT,
    session_count    INT
);

-- 14 Table stats
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

-- 32 Database summary
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

-- 15 Autovacuum activity
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

-- 23 Streaming replication lag
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

-- 31 Checkpoint / bgwriter stats
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

-- Indexes for trend query performance
CREATE INDEX IF NOT EXISTS idx_slow_queries_snap     ON perf_monitor.slow_queries(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_temp_pressure_snap    ON perf_monitor.temp_pressure(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_connections_snap      ON perf_monitor.connections(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_lock_waits_snap       ON perf_monitor.lock_waits(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_wait_events_snap      ON perf_monitor.wait_events(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_table_stats_snap      ON perf_monitor.table_stats(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_db_summary_snap       ON perf_monitor.db_summary(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_autovacuum_snap        ON perf_monitor.autovacuum_activity(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_replication_lag_snap   ON perf_monitor.replication_lag(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_checkpoint_stats_snap  ON perf_monitor.checkpoint_stats(snapshot_id);
