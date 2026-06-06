-- ============================================================
-- 04 · N+1 PATTERNS (HIGH-FREQUENCY FAST QUERIES)
-- ============================================================
-- What    : Queries called thousands of times, cheap individually
--           but expensive in aggregate — classic ORM N+1 symptom
-- Look for: calls > 10000 and mean_exec_ms < 10
-- Action  : Batch with IN clause; add caching; review ORM eager
--           loading; use prepared statements
-- Requires: pg_stat_statements
-- ============================================================

SELECT
    calls,
    round(mean_exec_time::numeric, 4)                              AS mean_exec_ms,
    round(total_exec_time::numeric, 2)                             AS total_exec_ms,
    round(rows::numeric / nullif(calls, 0), 2)                    AS rows_per_call,
    left(query, 200)                                               AS query_snippet
FROM pg_stat_statements
WHERE calls > 10000
  AND mean_exec_time < 10
ORDER BY calls DESC
LIMIT 20;
