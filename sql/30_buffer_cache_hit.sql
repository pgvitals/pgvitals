-- ============================================================
-- 30 · BUFFER CACHE HIT RATIO
-- ============================================================
-- What    : How often reads are served from shared_buffers vs disk
-- Look for: hit_ratio_pct < 95% on hot tables
-- Action  : Increase shared_buffers; investigate seq scan storms
--           pulling random data into cache and evicting hot pages
-- ============================================================

-- Per table
SELECT
    schemaname,
    tablename,
    heap_blks_read,
    heap_blks_hit,
    round(
        heap_blks_hit::numeric
        / nullif(heap_blks_read + heap_blks_hit, 0) * 100, 2
    )                                                                 AS hit_ratio_pct,
    idx_blks_read,
    idx_blks_hit,
    round(
        idx_blks_hit::numeric
        / nullif(idx_blks_read + idx_blks_hit, 0) * 100, 2
    )                                                                 AS idx_hit_ratio_pct
FROM pg_statio_user_tables
WHERE heap_blks_read + heap_blks_hit > 1000
ORDER BY heap_blks_read DESC
LIMIT 20;

-- Global database hit ratio
SELECT
    sum(blks_hit)                                                     AS total_hits,
    sum(blks_read)                                                    AS total_reads,
    round(
        sum(blks_hit)::numeric
        / nullif(sum(blks_hit) + sum(blks_read), 0) * 100, 2
    )                                                                 AS global_hit_ratio_pct
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1');
