-- ============================================================
-- 25 · REPLICATION SLOT WAL RETENTION
-- ============================================================
-- What    : Total WAL held on disk by ALL slots (streaming + logical)
-- Look for: wal_retained approaching your pg_wal partition free space
-- Action  : Drop inactive slots; advance or drop lagging slots
-- ============================================================

SELECT
    slot_name,
    slot_type,
    active,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    )                                                                 AS wal_retained,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)               AS wal_retained_bytes
FROM pg_replication_slots
ORDER BY wal_retained_bytes DESC NULLS LAST;

-- Total WAL held across all slots combined
SELECT pg_size_pretty(
    sum(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
) AS total_wal_held_by_slots
FROM pg_replication_slots;
