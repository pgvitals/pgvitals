-- ============================================================
-- pgvitals · capture_snapshot()
-- ============================================================
-- Captures a point-in-time snapshot of all key metrics into
-- the perf_monitor schema tables.
--
-- Usage:
--   SELECT perf_monitor.capture_snapshot('baseline');
--   SELECT perf_monitor.capture_snapshot('peak_load', 'after 500 users');
--
-- Returns: snapshot_id (BIGINT)
--
-- Automate every 30s during a load test:
--   \t on
--   SELECT perf_monitor.capture_snapshot('load_test'); \watch 30
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

    -- Slow queries (top 50 by total time)
    INSERT INTO perf_monitor.slow_queries
        (snapshot_id, captured_at, queryid, calls,
         total_exec_ms, mean_exec_ms, pct_total_time,
         temp_blks_written, rows_per_call, query_snippet)
    SELECT
        v_snapshot_id, v_now,
        queryid,
        calls,
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
