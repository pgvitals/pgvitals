-- ============================================================
-- 13 · TABLE & INDEX SIZE RANKING
-- ============================================================
-- What    : Largest objects ranked by total size
-- Look for: indexes_size >> heap_size (over-indexed tables)
--           toast_size unexpectedly large
-- Action  : Investigate large objects; review index necessity
-- ============================================================

SELECT
    schemaname,
    tablename,
    pg_size_pretty(
        pg_total_relation_size(schemaname || '.' || tablename)
    )                                                                  AS total_size,
    pg_size_pretty(
        pg_relation_size(schemaname || '.' || tablename)
    )                                                                  AS heap_size,
    pg_size_pretty(
        pg_indexes_size(schemaname || '.' || tablename)
    )                                                                  AS indexes_size,
    pg_size_pretty(
        pg_total_relation_size(schemaname || '.' || tablename)
        - pg_relation_size(schemaname || '.' || tablename)
        - pg_indexes_size(schemaname || '.' || tablename)
    )                                                                  AS toast_size,
    pg_total_relation_size(schemaname || '.' || tablename)             AS total_bytes
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY total_bytes DESC
LIMIT 30;
