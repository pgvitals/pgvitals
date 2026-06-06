-- ============================================================
-- 07 · DUPLICATE / REDUNDANT INDEXES
-- ============================================================
-- What    : Multiple indexes covering the exact same column set
-- Look for: Any row — duplicates add write overhead with no
--           query benefit
-- Action  : Keep the most specific one; DROP the rest
-- ============================================================

SELECT
    indrelid::regclass                                                      AS table_name,
    array_agg(indexrelid::regclass ORDER BY indexrelid)                    AS duplicate_indexes,
    array_agg(
        pg_size_pretty(pg_relation_size(indexrelid)) ORDER BY indexrelid
    )                                                                       AS sizes,
    indkey::text                                                            AS index_columns
FROM pg_index
GROUP BY indrelid, indkey
HAVING count(*) > 1
ORDER BY indrelid::regclass::text;
