-- ============================================================
-- 33 · WAL GENERATION RATE
-- ============================================================
-- What    : WAL (Write-Ahead Log) generation volume and rate since stats reset
-- Look for: High wal_mb_per_hour (e.g. > 1000 MB/hr) indicating write intensity;
--           high fpi_pct (> 20%) indicating potential checkpoint pressure
-- Action  : Enable wal_compression; tune max_wal_size and checkpoint_timeout;
--           investigate write-heavy queries or large updates
-- Requires: PostgreSQL 14+
-- ============================================================

SELECT
    wal_records,
    wal_fpi,
    pg_size_pretty(wal_bytes)                                                 AS total_wal_size,
    round(wal_bytes / 1024.0 / 1024.0, 2)                                     AS total_wal_mb,
    round(
        (wal_bytes / 1024.0 / 1024.0)
        / nullif(extract(epoch from (now() - stats_reset)) / 3600.0, 0)::numeric, 2
    )                                                                          AS wal_mb_per_hour,
    round(
        wal_fpi::numeric / nullif(wal_records, 0) * 100, 2
    )                                                                          AS fpi_pct,
    stats_reset
FROM pg_stat_wal;
