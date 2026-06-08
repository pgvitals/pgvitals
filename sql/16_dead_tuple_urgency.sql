-- ============================================================
-- 16 · DEAD TUPLE URGENCY (VACUUM BACKLOG)
-- ============================================================
-- What    : Tables accumulating dead tuples faster than vacuum clears
-- Look for: dead_pct > 10% | last_autovacuum = NULL or days ago
-- Action  : VACUUM ANALYZE tablename;
--           Tune autovacuum_vacuum_scale_factor (lower = more frequent)
-- ============================================================

SELECT
    schemaname,
    relname AS tablename,
    n_dead_tup,
    n_live_tup,
    round(
        n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 2
    )                                                                  AS dead_pct,
    n_mod_since_analyze,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    pg_size_pretty(
        pg_relation_size(relid)
    )                                                                  AS table_size
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 25;
