-- ============================================================
-- 02 · TEMP FILE & work_mem PRESSURE
-- ============================================================
-- What    : Queries spilling intermediate results to disk
-- Look for: Any temp_written_mb > 0 — every MB is a disk write
-- Action  : Increase work_mem for the session or tune join/sort
--           strategy; consider hash vs sort plan hints
-- Requires: pg_stat_statements
-- ============================================================

SELECT
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
LIMIT 20;
