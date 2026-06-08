-- ============================================================
-- 34 · PARTITIONED TABLE HEALTH
-- ============================================================
-- What    : Partitioned tables, partition counts, and total sizes
-- Look for: partition_count > 100 (high planning overhead);
--           partition_count = 0 (inserts will fail unless default partition exists)
-- Action  : Merge old partitions or partition by larger range (e.g. monthly);
--           create missing partitions if partition_count = 0
-- ============================================================

SELECT
    n.nspname                                                                  AS schemaname,
    c.relname                                                                  AS table_name,
    count(i.inhrelid)                                                          AS partition_count,
    pg_size_pretty(pg_total_relation_size(c.oid))                              AS total_size,
    pg_size_pretty(pg_relation_size(c.oid))                                    AS parent_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_inherits i ON i.inhparent = c.oid
WHERE c.relkind = 'p'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
GROUP BY n.nspname, c.relname, c.oid
ORDER BY partition_count DESC;
