-- ============================================================
-- 12 · TOAST TABLE BLOAT
-- ============================================================
-- What    : Oversized TOAST tables storing large column values
--           (text, jsonb, bytea, arrays)
-- Look for: toast_size >> table_size; toast_to_table_pct > 200%
-- Action  : VACUUM the parent table; consider compressing values
--           at the application layer; review column storage setting
-- ============================================================

SELECT
    n.nspname                                                         AS schemaname,
    c.relname                                                         AS tablename,
    pg_size_pretty(pg_relation_size(c.oid))                          AS table_size,
    pg_size_pretty(pg_relation_size(t.oid))                          AS toast_size,
    round(
        pg_relation_size(t.oid)::numeric
        / nullif(pg_relation_size(c.oid), 0) * 100, 2
    )                                                                 AS toast_to_table_pct
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_class t     ON t.oid = c.reltoastrelid
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND pg_relation_size(t.oid) > 1024 * 1024   -- TOAST > 1 MB
ORDER BY pg_relation_size(t.oid) DESC
LIMIT 20;
