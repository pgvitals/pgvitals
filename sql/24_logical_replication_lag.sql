-- ============================================================
-- 24 · LOGICAL REPLICATION SLOT LAG
-- ============================================================
-- What    : WAL accumulating for logical replication consumers
-- Look for: consumer_lag_size > 500 MB — risk of disk exhaustion
-- Action  : Check consumer health; if consumer is gone,
--           DROP the slot: SELECT pg_drop_replication_slot('name');
-- ============================================================

SELECT
    slot_name,
    plugin,
    database,
    active,
    active_pid,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
    )                                                                 AS consumer_lag_size,
    pg_wal_lsn_diff(
        pg_current_wal_lsn(), confirmed_flush_lsn
    )                                                                 AS consumer_lag_bytes
FROM pg_replication_slots
WHERE slot_type = 'logical'
ORDER BY consumer_lag_bytes DESC NULLS LAST;
