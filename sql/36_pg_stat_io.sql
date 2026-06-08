-- ============================================================
-- 36 · I/O STATS BY BACKEND (pg_stat_io)
-- ============================================================
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
