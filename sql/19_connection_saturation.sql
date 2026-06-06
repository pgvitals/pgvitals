-- ============================================================
-- 19 · CONNECTION SATURATION
-- ============================================================
-- What    : Current connections vs max_connections headroom
-- Look for: used_pct > 80% — approaching the connection limit
-- Action  : Add PgBouncer or another connection pooler;
--           audit idle connections; reduce application pool size
-- ============================================================

-- Summary
SELECT
    count(*)                                                               AS total,
    count(*) FILTER (WHERE state = 'active')                              AS active,
    count(*) FILTER (WHERE state = 'idle')                                AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction')                 AS idle_in_txn,
    count(*) FILTER (WHERE state = 'idle in transaction (aborted)')       AS idle_in_txn_aborted,
    count(*) FILTER (WHERE wait_event IS NOT NULL AND state = 'active')   AS waiting,
    s.setting::int                                                         AS max_connections,
    round(count(*)::numeric / s.setting::int * 100, 2)                   AS used_pct,
    s.setting::int - count(*)                                              AS free_slots
FROM pg_stat_activity, pg_settings s
WHERE s.name = 'max_connections'
  AND pg_stat_activity.pid <> pg_backend_pid()
GROUP BY s.setting;

-- Per application breakdown
SELECT
    application_name,
    state,
    count(*) AS connections
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY application_name, state
ORDER BY count(*) DESC
LIMIT 20;
