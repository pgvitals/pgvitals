-- ============================================================
-- 27 · MULTIXACT ID (MXID) WRAPAROUND RISK
-- ============================================================
-- What    : Distance from MultiXact exhaustion — a separate
--           counter used when rows have multiple row-level locks
-- Look for: mxid_age > 1 billion → tables need VACUUM FREEZE
-- Action  : VACUUM FREEZE tablename; lower autovacuum_multixact_freeze_max_age
-- ============================================================

SELECT
    datname,
    mxid_age(datminmxid)                                             AS mxid_age,
    2147483647 - mxid_age(datminmxid)                               AS mxid_remaining,
    round(mxid_age(datminmxid)::numeric / 2147483647 * 100, 2)     AS pct_used
FROM pg_database
ORDER BY mxid_age(datminmxid) DESC;
