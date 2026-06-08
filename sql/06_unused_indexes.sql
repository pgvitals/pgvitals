-- ============================================================
-- 06 · UNUSED INDEXES
-- ============================================================
-- What    : Indexes that have never been used in a query scan
--           since the last pg_stat_reset
-- Look for: idx_scan = 0 on non-primary, non-unique indexes
-- Action  : DROP after verifying stats haven't been reset
--           recently; check for indexes used only at night
-- ============================================================

SELECT
    s.schemaname,
    s.relname AS tablename,
    s.indexrelname AS indexname,
    pg_size_pretty(pg_relation_size(s.indexrelid))          AS index_size,
    s.idx_scan,
    s.idx_tup_read,
    s.idx_tup_fetch
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisprimary
  AND NOT i.indisunique
  AND pg_relation_size(s.indexrelid) > 0
ORDER BY pg_relation_size(s.indexrelid) DESC;

-- Stats reset time (to judge staleness of idx_scan = 0)
SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();
