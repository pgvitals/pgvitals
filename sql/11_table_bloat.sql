-- ============================================================
-- 11 · TABLE BLOAT (ESTIMATION)
-- ============================================================
-- What    : Tables with large amounts of dead / unreclaimable space
-- Look for: bloat_pct_estimate > 20% or bloat_size > 100 MB
-- Action  : VACUUM ANALYZE table (online, may need multiple passes)
--           pg_repack (online, no lock) or VACUUM FULL (full lock)
-- Note    : Estimate based on pg_stats; run ANALYZE first for
--           accuracy. For exact bloat use pgstattuple extension.
-- ============================================================

WITH constants AS (
    SELECT current_setting('block_size')::int AS bs,
           23                                 AS hdr,
           8                                  AS ma
),
per_table AS (
    SELECT
        ns.nspname                                                     AS schemaname,
        tbl.relname                                                    AS tablename,
        tbl.relpages,
        tbl.reltuples,
        bs,
        (
            sum((1 - s.null_frac) * s.avg_width)::int
            + hdr + ma
            - CASE WHEN hdr % ma = 0 THEN ma ELSE hdr % ma END
        )                                                              AS row_data_width
    FROM pg_class tbl
    JOIN pg_namespace ns    ON ns.oid = tbl.relnamespace
    JOIN pg_attribute att   ON att.attrelid = tbl.oid
                            AND att.attnum > 0
                            AND NOT att.attisdropped
    JOIN pg_stats s         ON s.schemaname = ns.nspname
                            AND s.tablename  = tbl.relname
                            AND s.attname    = att.attname
    CROSS JOIN constants
    WHERE tbl.relkind = 'r'
      AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
    GROUP BY ns.nspname, tbl.relname, tbl.relpages, tbl.reltuples, bs, hdr, ma
)
SELECT
    schemaname,
    tablename,
    relpages                                                           AS actual_pages,
    round(reltuples)                                                   AS est_row_count,
    pg_size_pretty((relpages * bs)::bigint)                           AS total_size,
    pg_size_pretty(
        greatest(0, relpages - ceil(reltuples * row_data_width / bs))::bigint * bs
    )                                                                  AS bloat_size_estimate,
    round(
        greatest(0, 1 - ceil(reltuples * row_data_width / bs)
                        / nullif(relpages, 0)) * 100, 2
    )                                                                  AS bloat_pct_estimate
FROM per_table
WHERE relpages > 10
ORDER BY greatest(0, relpages - ceil(reltuples * row_data_width / bs)) DESC
LIMIT 20;
