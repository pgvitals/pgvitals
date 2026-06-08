-- ============================================================
-- 32 · DATABASE-LEVEL SUMMARY
-- ============================================================
-- What    : Per-database throughput, cache hit, deadlocks, temp usage
-- Look for: rollback_pct > 5% | deadlocks > 0 | cache_hit_pct < 95%
-- Action  : Investigate rollback sources; add deadlock_timeout logging; tune shared_buffers
-- ============================================================

SELECT
    datname,
    numbackends                                                        AS active_backends,
    xact_commit,
    xact_rollback,
    round(
        xact_rollback::numeric / nullif(xact_commit + xact_rollback, 0) * 100, 2
    )                                                                  AS rollback_pct,
    blks_read,
    blks_hit,
    round(
        blks_hit::numeric / nullif(blks_read + blks_hit, 0) * 100, 2
    )                                                                  AS cache_hit_pct,
    tup_returned,
    tup_fetched,
    tup_inserted,
    tup_updated,
    tup_deleted,
    conflicts,
    temp_files,
    pg_size_pretty(temp_bytes)                                        AS temp_usage,
    deadlocks,
    pg_size_pretty(pg_database_size(datname))                        AS db_size,
    now() - stats_reset                                               AS stats_age
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY numbackends DESC;
