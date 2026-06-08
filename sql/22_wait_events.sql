-- ============================================================
-- 22 · WAIT EVENTS BREAKDOWN
-- ============================================================
-- What    : What all active sessions are currently waiting on
-- Look for: Lock waits > a few sessions (contention)
--           LWLock:WALWrite / IO:DataFileRead spikes (I/O bound)
--           Client:ClientRead (application not reading fast enough)
-- Action  : Cross-reference with lock tree; investigate I/O if DataFileRead dominates
-- ============================================================

SELECT
    wait_event_type,
    wait_event,
    count(*)                                                          AS sessions,
    array_agg(pid ORDER BY pid)                                      AS pids
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
  AND pid <> pg_backend_pid()
GROUP BY wait_event_type, wait_event
ORDER BY sessions DESC;
