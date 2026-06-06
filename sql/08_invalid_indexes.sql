-- ============================================================
-- 08 · INVALID INDEXES
-- ============================================================
-- What    : Indexes left in invalid state — typically from a
--           failed CREATE INDEX CONCURRENTLY
-- Look for: Any row — invalid indexes waste space and are
--           never used by the planner
-- Action  : DROP index_name; then recreate with CONCURRENTLY
-- ============================================================

SELECT
    n.nspname                                              AS schemaname,
    c.relname                                              AS tablename,
    i.relname                                              AS indexname,
    pg_size_pretty(pg_relation_size(i.oid))               AS wasted_size
FROM pg_index x
JOIN pg_class c ON c.oid = x.indrelid
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT x.indisvalid
  AND n.nspname NOT IN ('pg_catalog', 'information_schema');
