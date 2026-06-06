-- ============================================================
-- pgvitals · Trend & Delta Analysis
-- ============================================================
-- Run these after collecting snapshots during a load test.
-- Replace :snap_a / :snap_b with actual snapshot IDs,
-- or use label-based CTEs shown below.
-- ============================================================

-- List all snapshots
SELECT snapshot_id, captured_at, label, notes
FROM perf_monitor.snapshots
ORDER BY captured_at;


-- ── CONNECTION TREND ────────────────────────────────────────
-- Connection saturation over all snapshots
SELECT
    s.captured_at,
    s.label,
    c.total,
    c.active,
    c.idle_in_txn,
    c.waiting,
    c.used_pct
FROM perf_monitor.connections c
JOIN perf_monitor.snapshots s USING (snapshot_id)
ORDER BY s.captured_at;


-- ── CONNECTION DELTA (two specific snapshots) ────────────────
-- Replace :snap_a / :snap_b with snapshot IDs
WITH a AS (SELECT * FROM perf_monitor.connections WHERE snapshot_id = :snap_a),
     b AS (SELECT * FROM perf_monitor.connections WHERE snapshot_id = :snap_b)
SELECT
    b.captured_at                          AS snap_b_time,
    b.total       - a.total               AS total_delta,
    b.active      - a.active              AS active_delta,
    b.idle_in_txn - a.idle_in_txn         AS idle_txn_delta,
    b.used_pct    - a.used_pct             AS used_pct_delta
FROM a, b;


-- ── LOCK WAIT SPIKES ────────────────────────────────────────
-- Lock wait count per snapshot (spikes = contention events)
SELECT
    s.captured_at,
    s.label,
    count(l.blocked_pid)                   AS lock_waits
FROM perf_monitor.snapshots s
LEFT JOIN perf_monitor.lock_waits l USING (snapshot_id)
GROUP BY s.snapshot_id, s.captured_at, s.label
ORDER BY s.captured_at;


-- ── TOP WAIT EVENTS ACROSS ALL SNAPSHOTS ────────────────────
SELECT
    wait_event_type,
    wait_event,
    sum(session_count)                     AS total_occurrences,
    round(avg(session_count), 2)           AS avg_per_snapshot,
    max(session_count)                     AS peak_sessions
FROM perf_monitor.wait_events w
JOIN perf_monitor.snapshots s USING (snapshot_id)
GROUP BY wait_event_type, wait_event
ORDER BY total_occurrences DESC
LIMIT 20;


-- ── DEAD TUPLE GROWTH (baseline → peak) ─────────────────────
WITH snap_a AS (
    SELECT snapshot_id FROM perf_monitor.snapshots WHERE label = 'baseline' LIMIT 1
),
snap_b AS (
    SELECT snapshot_id FROM perf_monitor.snapshots WHERE label = 'peak' LIMIT 1
)
SELECT
    a.schemaname,
    a.tablename,
    a.n_dead_tup                           AS dead_at_baseline,
    b.n_dead_tup                           AS dead_at_peak,
    b.n_dead_tup - a.n_dead_tup           AS dead_growth,
    b.seq_scan   - a.seq_scan             AS seq_scan_delta,
    b.idx_scan   - a.idx_scan             AS idx_scan_delta
FROM perf_monitor.table_stats a
JOIN perf_monitor.table_stats b
    ON  b.schemaname   = a.schemaname
    AND b.tablename    = a.tablename
WHERE a.snapshot_id = (SELECT snapshot_id FROM snap_a)
  AND b.snapshot_id = (SELECT snapshot_id FROM snap_b)
ORDER BY dead_growth DESC
LIMIT 20;


-- ── CACHE HIT RATIO TREND ────────────────────────────────────
SELECT
    s.captured_at,
    s.label,
    round(avg(t.hit_ratio_pct), 2)        AS avg_cache_hit_pct,
    min(t.hit_ratio_pct)                   AS min_cache_hit_pct
FROM perf_monitor.table_stats t
JOIN perf_monitor.snapshots s USING (snapshot_id)
WHERE t.heap_blks_read + t.heap_blks_hit > 0
GROUP BY s.snapshot_id, s.captured_at, s.label
ORDER BY s.captured_at;


-- ── DEADLOCK TREND ───────────────────────────────────────────
SELECT
    s.captured_at,
    s.label,
    sum(d.deadlocks)                       AS deadlocks
FROM perf_monitor.db_summary d
JOIN perf_monitor.snapshots s USING (snapshot_id)
GROUP BY s.snapshot_id, s.captured_at, s.label
ORDER BY s.captured_at;


-- ── CHECKPOINT PRESSURE TREND ────────────────────────────────
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


-- ── TEMP FILE SPILL TREND ────────────────────────────────────
SELECT
    s.captured_at,
    s.label,
    sum(t.temp_blks_written)              AS total_temp_blks,
    round(sum(t.temp_written_mb), 2)      AS total_temp_mb
FROM perf_monitor.temp_pressure t
JOIN perf_monitor.snapshots s USING (snapshot_id)
GROUP BY s.snapshot_id, s.captured_at, s.label
ORDER BY s.captured_at;


-- ── ROLLBACK RATE TREND ──────────────────────────────────────
SELECT
    s.captured_at,
    s.label,
    sum(d.xact_commit)                    AS commits,
    sum(d.xact_rollback)                  AS rollbacks,
    round(avg(d.rollback_pct), 2)         AS avg_rollback_pct
FROM perf_monitor.db_summary d
JOIN perf_monitor.snapshots s USING (snapshot_id)
GROUP BY s.snapshot_id, s.captured_at, s.label
ORDER BY s.captured_at;
