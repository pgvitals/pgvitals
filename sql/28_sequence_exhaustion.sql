-- ============================================================
-- 28 · SEQUENCE EXHAUSTION RISK
-- ============================================================
-- What    : Sequences approaching their max value (integer overflow)
-- Look for: pct_used > 80% — plan a migration before hitting 100%
--           int sequences at any significant % (max = 2.1B)
--           bigint sequences are rarely a concern (max = 9.2E18)
-- Action  : ALTER SEQUENCE seq MAXVALUE new_max;
--           or ALTER TABLE t ALTER COLUMN id TYPE bigint;
-- ============================================================

SELECT
    schemaname,
    sequencename,
    data_type,
    last_value,
    min_value,
    max_value,
    increment_by,
    cycle,
    round(
        (last_value - min_value)::numeric
        / nullif(max_value - min_value, 0) * 100, 2
    )                                                                 AS pct_used,
    (max_value - last_value) / nullif(increment_by, 0)               AS values_remaining
FROM pg_sequences
WHERE NOT cycle
  AND last_value IS NOT NULL
ORDER BY pct_used DESC NULLS LAST
LIMIT 20;
