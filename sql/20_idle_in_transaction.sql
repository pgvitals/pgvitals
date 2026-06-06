-- ============================================================
-- 20 · IDLE-IN-TRANSACTION CONNECTIONS
-- ============================================================
-- What    : Sessions sitting idle inside an open transaction
--           — silently hold locks and block autovacuum
-- Look for: idle_duration > 30 seconds
-- Action  : Fix application to commit/rollback promptly;
--           SET idle_in_transaction_session_timeout = '30s';
-- ============================================================

SELECT
    pid,
    usename,
    application_name,
    client_addr,
    now() - state_change                                              AS idle_duration,
    now() - xact_start                                                AS txn_open_duration,
    left(query, 200)                                                   AS last_query
FROM pg_stat_activity
WHERE state IN ('idle in transaction', 'idle in transaction (aborted)')
ORDER BY state_change ASC;
