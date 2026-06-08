-- ============================================================
-- 03 · SEQUENTIAL SCAN HOTSPOTS
-- ============================================================
-- What    : Tables hit mostly with full sequential scans
-- Look for: seq_scan_pct > 50% on tables with n_live_tup > 10k
-- Action  : Add a targeted index on the filtered columns;
--           verify the planner is picking it up with EXPLAIN
-- ============================================================

SELECT
    schemaname,
    relname AS tablename,
    seq_scan,
    seq_tup_read,
    idx_scan,
    round(seq_scan::numeric / nullif(seq_scan + idx_scan, 0) * 100, 2)    AS seq_scan_pct,
    n_live_tup,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size
FROM pg_stat_user_tables
WHERE seq_scan > 0
  AND n_live_tup > 10000
ORDER BY seq_scan DESC
LIMIT 20;
