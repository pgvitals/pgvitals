-- ============================================================
-- 14 · TABLE ACCESS PATTERNS
-- ============================================================
-- What    : Heap vs index fetch ratio, write load, dead tuple ratio
-- Look for: High seq_tup_read + low idx_tup_fetch → missing index
--           High n_tup_upd + high n_dead_tup → vacuum lag
--           dead_pct > 10% → VACUUM urgently needed
-- Action  : Add index for seq scan tables; run VACUUM ANALYZE for high dead_pct
-- ============================================================

SELECT
    schemaname,
    tablename,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    n_tup_ins,
    n_tup_upd,
    n_tup_del,
    n_tup_hot_upd,
    n_live_tup,
    n_dead_tup,
    round(
        n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 2
    )                                                                  AS dead_pct
FROM pg_stat_user_tables
ORDER BY seq_tup_read + idx_tup_fetch DESC
LIMIT 25;
