-- ============================================================
-- 17 · STALE STATISTICS (ANALYZE OVERDUE)
-- ============================================================
-- What    : Tables with many row modifications since last ANALYZE
--           — stale stats lead the planner to pick bad plans
-- Look for: mod_pct > 10% | time_since_analyze > 1 day on hot tables
-- Action  : ANALYZE tablename;
--           Lower autovacuum_analyze_scale_factor for busy tables
-- ============================================================

SELECT
    schemaname,
    tablename,
    n_live_tup,
    n_mod_since_analyze,
    round(
        n_mod_since_analyze::numeric / nullif(n_live_tup, 0) * 100, 2
    )                                                                  AS mod_pct,
    last_analyze,
    last_autoanalyze,
    now() - greatest(last_analyze, last_autoanalyze)                  AS time_since_analyze
FROM pg_stat_user_tables
WHERE n_live_tup > 1000
ORDER BY n_mod_since_analyze DESC
LIMIT 20;
