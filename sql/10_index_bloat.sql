-- ============================================================
-- 10 · INDEX BLOAT (ESTIMATION)
-- ============================================================
-- What    : Indexes with high fragmentation (free-space waste)
-- Look for: bloat_pct_estimate > 30% on large indexes
-- Action  : REINDEX CONCURRENTLY indexname
-- Note    : This is a statistical estimate. For exact figures:
--           CREATE EXTENSION pgstattuple;
--           SELECT * FROM pgstattuple('indexname');
-- ============================================================

WITH index_info AS (
    SELECT
        n.nspname                                              AS schemaname,
        ct.relname                                             AS tablename,
        ci.relname                                             AS indexname,
        ci.oid                                                 AS indexrelid,
        pg_relation_size(ci.oid)                               AS index_bytes,
        ci.relpages                                            AS actual_pages,
        ceil(ci.reltuples * 14                                 -- avg index tuple overhead estimate
             / (current_setting('block_size')::int * 0.8)
        )                                                      AS estimated_min_pages
    FROM pg_index x
    JOIN pg_class ci ON ci.oid = x.indexrelid
    JOIN pg_class ct ON ct.oid = x.indrelid
    JOIN pg_namespace n ON n.oid = ci.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND ci.relpages > 0
)
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(index_bytes)                                            AS index_size,
    actual_pages,
    estimated_min_pages::int,
    round(
        ((1 - estimated_min_pages / nullif(actual_pages, 0)) * 100)::numeric, 2
    )                                                                      AS bloat_pct_estimate
FROM index_info
WHERE index_bytes > 1024 * 1024   -- only show indexes > 1 MB
  AND actual_pages > estimated_min_pages
ORDER BY index_bytes DESC
LIMIT 20;
