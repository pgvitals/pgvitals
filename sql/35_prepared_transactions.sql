-- ============================================================
-- 35 · OPEN PREPARED TRANSACTIONS
-- ============================================================
-- What    : Uncommitted prepared transactions (2PC/two-phase commit)
-- Look for: Any row older than 5 minutes (blocks vacuum, holds locks)
-- Action  : Run COMMIT PREPARED '<gid>'; or ROLLBACK PREPARED '<gid>';
-- ============================================================

SELECT
    gid,
    prepared,
    owner,
    database,
    now() - prepared                                                          AS age,
    transaction::text                                                          AS xid
FROM pg_prepared_xacts
ORDER BY prepared ASC;
