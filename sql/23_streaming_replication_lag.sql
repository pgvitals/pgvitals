-- ============================================================
-- 23 · STREAMING REPLICATION LAG
-- ============================================================
-- What    : Per-standby write, flush, and replay lag
-- Look for: replay_lag > 30s | flush_lag > 10s
-- Action  : Check standby I/O; verify network throughput;
--           review recovery.conf / primary_conninfo settings
-- ============================================================

SELECT
    application_name,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    write_lag,
    flush_lag,
    replay_lag,
    sync_state,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)
    )                                                                 AS unsent_wal
FROM pg_stat_replication
ORDER BY replay_lag DESC NULLS LAST;
