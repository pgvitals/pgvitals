-- ============================================================
-- 31 · CHECKPOINT & WAL PRESSURE
-- ============================================================
-- What    : Whether checkpoints are forced too frequently and
--           whether backends are writing directly to WAL
-- Look for: forced_pct > 10% → increase max_wal_size
--           buffers_backend_fsync > 0 → critical, backends are
--           fsyncing (shared_buffers or bgwriter can't keep up)
-- Action  : Increase max_wal_size; set checkpoint_completion_target=0.9
-- ============================================================

SELECT
    checkpoints_timed,
    checkpoints_req,
    round(
        checkpoints_req::numeric
        / nullif(checkpoints_timed + checkpoints_req, 0) * 100, 2
    )                                                                 AS forced_pct,
    round(checkpoint_write_time / 1000, 2)                           AS write_time_sec,
    round(checkpoint_sync_time / 1000, 2)                            AS sync_time_sec,
    buffers_checkpoint,
    buffers_clean,
    maxwritten_clean,
    buffers_backend,
    buffers_backend_fsync,
    buffers_alloc,
    now() - stats_reset                                               AS stats_age
FROM pg_stat_bgwriter;
