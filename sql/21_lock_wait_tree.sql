-- ============================================================
-- 21 · LOCK WAIT TREE (BLOCKING CHAINS)
-- ============================================================
-- What    : Full chain of who is blocking whom
-- Look for: Any row — every lock wait degrades throughput
-- Action  : Find root blocker (the one where blocking_pids = '{}')
--           and investigate or terminate: SELECT pg_terminate_backend(pid)
-- ============================================================

-- Blocking summary
SELECT
    pid                                                                AS blocked_pid,
    usename                                                            AS blocked_user,
    pg_blocking_pids(pid)                                             AS blocking_pids,
    cardinality(pg_blocking_pids(pid))                                AS blocking_depth,
    wait_event_type,
    wait_event,
    state,
    now() - query_start                                               AS waiting_duration,
    left(query, 200)                                                   AS blocked_query
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0
ORDER BY waiting_duration DESC;

-- Detailed lock mode breakdown
SELECT
    l.pid,
    l.locktype,
    l.relation::regclass                                              AS locked_object,
    l.mode,
    l.granted,
    a.usename,
    a.state,
    left(a.query, 150)                                                AS query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE NOT l.granted
   OR l.pid IN (
       SELECT unnest(pg_blocking_pids(pid))
       FROM pg_stat_activity
       WHERE cardinality(pg_blocking_pids(pid)) > 0
   )
ORDER BY l.pid;
