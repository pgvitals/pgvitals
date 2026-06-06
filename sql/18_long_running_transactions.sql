-- ============================================================
-- 18 · LONG-RUNNING TRANSACTIONS
-- ============================================================
-- What    : Open transactions blocking autovacuum and holding locks
-- Look for: xact_duration > 5 minutes
-- Action  : SELECT pg_terminate_backend(pid) after investigation;
--           set statement_timeout / idle_in_transaction_session_timeout
-- ============================================================

SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    now() - xact_start                                                AS xact_duration,
    now() - query_start                                               AS query_duration,
    left(query, 200)                                                   AS current_query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes'
  AND pid <> pg_backend_pid()
ORDER BY xact_start ASC;
