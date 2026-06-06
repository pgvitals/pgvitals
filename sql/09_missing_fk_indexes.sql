-- ============================================================
-- 09 · MISSING FOREIGN KEY INDEXES
-- ============================================================
-- What    : FK columns with no supporting index — causes seq
--           scans on cascades, ON DELETE, and JOIN operations
-- Look for: Any row — almost always worth indexing
-- Action  : CREATE INDEX ON table(fk_column);
-- ============================================================

SELECT
    c.conrelid::regclass                                              AS table_name,
    c.conname                                                         AS constraint_name,
    string_agg(a.attname, ', ' ORDER BY x.n)                        AS fk_columns
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum
WHERE c.contype = 'f'
  AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.conrelid
        AND (i.indkey::int2[])[0 : array_length(c.conkey, 1) - 1]
            @> c.conkey
  )
GROUP BY c.conrelid, c.conname
ORDER BY table_name;
