-- ============================================================
-- 01 · SLOW / EXPENSIVE QUERIES
-- ============================================================
-- What    : Top queries ranked by total CPU time consumed
-- Look for: mean_exec_ms > 100ms | pct_total_time > 10%
-- Action  : EXPLAIN ANALYZE the top offenders; add indexes or
--           rewrite query logic
-- Requires: pg_stat_statements
-- ============================================================

SELECT
    round(total_exec_time::numeric, 2)                                        AS total_exec_ms,
    calls,
    round(mean_exec_time::numeric, 2)                                         AS mean_exec_ms,
    round(stddev_exec_time::numeric, 2)                                       AS stddev_exec_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS pct_total_time,
    rows,
    round(rows::numeric / nullif(calls, 0), 2)                               AS rows_per_call,
    shared_blks_hit,
    shared_blks_read,
    round(shared_blks_hit::numeric
        / nullif(shared_blks_hit + shared_blks_read, 0) * 100, 2)            AS cache_hit_pct,
    left(query, 200)                                                           AS query_snippet
FROM pg_stat_statements
WHERE calls > 10
ORDER BY total_exec_time DESC
LIMIT 25;
